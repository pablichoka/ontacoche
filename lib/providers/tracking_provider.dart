import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_position.dart';
import '../models/tracking_flow.dart';
import '../models/telemetry_record.dart';
import '../utils/parsers.dart';
import 'api_provider.dart';
import 'telemetry_provider.dart';

final trackedDeviceIdProvider = Provider<String>((Ref ref) {
  return (dotenv.env['DEVICE_ID'] ?? '').trim();
});

final initialTrackingProvider =
    NotifierProvider<InitialTrackingController, InitialTrackingState>(
      InitialTrackingController.new,
    );

class InitialTrackingController extends Notifier<InitialTrackingState> {
  bool _disposed = false;
  bool _initialized = false;
  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _deviceStateSubscription;
  DateTime? _lastRealtimeTimestamp;
  String? _lastRealtimeSignature;

  static const Duration _remoteSyncInterval = Duration(seconds: 20);
  static const String _defaultStateCollection = 'device_last_state';

  @override
  InitialTrackingState build() {
    ref.onDispose(() {
      _disposed = true;
      _syncTimer?.cancel();
      _deviceStateSubscription?.cancel();
    });

    if (!_initialized) {
      _initialized = true;
      Future<void>.microtask(_initialize);
    }

    return const InitialTrackingState.connecting();
  }

  Future<void> _initialize() async {
    if (_disposed) {
      return;
    }

    _bindRealtimeDeviceState();

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_remoteSyncInterval, (_) {
      if (_disposed) {
        return;
      }
      unawaited(syncFromRemote());
    });

    unawaited(syncFromRemote());
  }

  void _bindRealtimeDeviceState() {
    final String collectionName =
        (dotenv.env['DEVICE_STATE_COLLECTION'] ?? '').trim().isEmpty
        ? _defaultStateCollection
        : (dotenv.env['DEVICE_STATE_COLLECTION'] ?? '').trim();

    final String configuredDeviceId = ref.read(trackedDeviceIdProvider);
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection(collectionName)
        .limit(1);

    if (configuredDeviceId.isNotEmpty) {
      query = FirebaseFirestore.instance
          .collection(collectionName)
          .where('device_id', isEqualTo: configuredDeviceId)
          .limit(1);
    }

    _deviceStateSubscription?.cancel();
    _deviceStateSubscription = query
        .snapshots()
        .listen(
          (QuerySnapshot<Map<String, dynamic>> snapshot) {
            if (_disposed || snapshot.docs.isEmpty) {
              return;
            }
            DocumentSnapshot<Map<String, dynamic>> selected =
                snapshot.docs.first;

            final Map<String, dynamic>? selectedData = selected.data();
            final String resolvedDeviceId = configuredDeviceId.isNotEmpty
                ? configuredDeviceId
                : ((selectedData?['device_id'] ?? '').toString().isNotEmpty
                      ? selectedData!['device_id'].toString()
                      : selected.id);

            unawaited(_handleRealtimeSnapshot(selected, resolvedDeviceId));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_disposed) {
              return;
            }

            state = state.copyWith(
              errorMessage: 'Realtime listener error: $error',
            );
          },
        );
  }

  Future<void> _handleRealtimeSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
    String deviceId,
  ) async {
    if (_disposed || !snapshot.exists) {
      return;
    }

    final Map<String, dynamic>? data = snapshot.data();
    if (data == null) {
      return;
    }

    final DevicePosition? realtimePosition = _positionFromStateDocument(data);
    if (realtimePosition == null) {
      return;
    }

    final String signature =
        '${data['source_ts_ms'] ?? data['source_ts'] ?? data['updated_at'] ?? ''}'
        '|${data['latitude'] ?? ''}|${data['longitude'] ?? ''}|${data['speed'] ?? ''}';
    if (_lastRealtimeSignature == signature) {
      return;
    }
    _lastRealtimeSignature = signature;

    final DateTime eventTimestamp =
        realtimePosition.timestamp ?? Parsers.now();
    if (_lastRealtimeTimestamp != null &&
        !eventTimestamp.isAfter(_lastRealtimeTimestamp!)) {
      return;
    }
    _lastRealtimeTimestamp = eventTimestamp;

    final TelemetryRecord record = TelemetryRecord.fromDevicePosition(
      deviceId: deviceId,
      position: realtimePosition,
    );

    await ref.read(telemetryDatabaseServiceProvider).insertRecord(record);
    if (_disposed) {
      return;
    }

    ref.invalidate(latestStoredTelemetryProvider);
    ref.invalidate(telemetryCountProvider);

    state = state.copyWith(
      status: TrackingServiceStatus.ok,
      source: InitialTrackingSource.remote,
      position: realtimePosition,
      resolvedAt: eventTimestamp,
      clearErrorMessage: true,
    );
  }

  DevicePosition? _positionFromStateDocument(Map<String, dynamic> stateData) {
    final Object? rawPosition = stateData['position'];
    final Map<String, dynamic>? positionMap = rawPosition is Map
        ? Map<String, dynamic>.from(rawPosition)
        : null;

    final double? latitude = DevicePosition.readDouble(
      positionMap?['latitude'] ?? stateData['latitude'] ?? stateData['lat'],
    );
    final double? longitude = DevicePosition.readDouble(
      positionMap?['longitude'] ??
          stateData['longitude'] ??
          stateData['lon'] ??
          stateData['lng'],
    );

    final GeoPoint? geoPoint = rawPosition is GeoPoint ? rawPosition : null;
    final double? resolvedLatitude = latitude ?? geoPoint?.latitude;
    final double? resolvedLongitude = longitude ?? geoPoint?.longitude;

    if (resolvedLatitude == null || resolvedLongitude == null) {
      return null;
    }

    final DateTime? timestamp =
        Parsers.fromUnknown(stateData['source_ts']) ??
        _fromMilliseconds(stateData['source_ts_ms']) ??
        Parsers.fromUnknown(stateData['updated_at']);

    return DevicePosition(
      latitude: resolvedLatitude,
      longitude: resolvedLongitude,
      altitude: DevicePosition.readDouble(
        positionMap?['altitude'] ?? stateData['altitude'],
      ),
      speed: DevicePosition.readDouble(
        positionMap?['speed'] ?? stateData['speed'],
      ),
      timestamp: timestamp,
      batteryLevel: DevicePosition.readDouble(
        stateData['battery_level'] ?? stateData['battery.level'],
      ),
    );
  }

  DateTime? _fromMilliseconds(Object? value) {
    if (value is! num) {
      return null;
    }

    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt(),
      isUtc: true,
    ).toLocal();
  }

  Future<void> syncFromRemote() async {
    if (!state.hasPosition) {
      state = state.copyWith(
        status: TrackingServiceStatus.connecting,
        source: InitialTrackingSource.fallback,
        clearErrorMessage: true,
      );
    }

    bool remoteUpdated = false;

    try {
      final String deviceId = ref.read(trackedDeviceIdProvider);
      DevicePosition? remotePosition;

      if (deviceId.isNotEmpty) {
        remotePosition = await ref
            .read(vercelConnectorServiceProvider)
            .getCurrentDeviceState(deviceId);
      }

      if (_disposed) {
        return;
      }

      if (remotePosition != null) {
        if (_lastRealtimeTimestamp != null &&
            remotePosition.timestamp != null &&
            !remotePosition.timestamp!.isAfter(_lastRealtimeTimestamp!)) {
          remotePosition = null;
        }

        if (deviceId.isNotEmpty) {
          if (remotePosition != null) {
            final TelemetryRecord record = TelemetryRecord.fromDevicePosition(
              deviceId: deviceId,
              position: remotePosition,
            );
            await ref
                .read(telemetryDatabaseServiceProvider)
                .insertRecord(record);
            ref.invalidate(latestStoredTelemetryProvider);
            ref.invalidate(telemetryCountProvider);
            remoteUpdated = true;
          }
        }
      }
    } catch (error) {
      if (_disposed) {
        return;
      }

      state = state.copyWith(errorMessage: error.toString());
    }

    final TelemetryRecord? stored = await ref
        .read(telemetryDatabaseServiceProvider)
        .fetchLatestRecord();
    if (_disposed) {
      return;
    }

    if (stored == null) {
      state = state.copyWith(
        status: TrackingServiceStatus.failure,
        source: InitialTrackingSource.fallback,
        errorMessage:
            state.errorMessage ?? 'No se encontró ninguna posición inicial',
        clearPosition: true,
        clearResolvedAt: true,
      );
      return;
    }

    final DevicePosition storedPosition = DevicePosition(
      latitude: stored.latitude,
      longitude: stored.longitude,
      altitude: stored.altitude,
      speed: stored.speed,
      timestamp: stored.recordedAt,
      batteryLevel: stored.batteryLevel,
    );

    state = state.copyWith(
      status: TrackingServiceStatus.ok,
      source: remoteUpdated
          ? InitialTrackingSource.remote
          : (state.source == InitialTrackingSource.remote
                ? InitialTrackingSource.remote
                : InitialTrackingSource.persisted),
      position: storedPosition,
      resolvedAt: stored.recordedAt,
      clearErrorMessage: true,
    );
  }
}

final initialTrackingIndicatorProvider = Provider<TrackingIndicatorData>((
  Ref ref,
) {
  final InitialTrackingState state = ref.watch(initialTrackingProvider);
  return TrackingIndicatorData(
    kind: TrackingIndicatorKind.initial,
    status: state.status,
    tooltip: switch (state.status) {
      TrackingServiceStatus.connecting => 'Lo estamos buscando',
      TrackingServiceStatus.ok => 'Coche encontrado',
      TrackingServiceStatus.failure => 'Ontacoche? :((',
    },
  );
});

final realtimeTrackingStatusProvider = Provider<TrackingServiceStatus>((
  Ref ref,
) {
  final AsyncValue<TelemetryRecord?> latest = ref.watch(
    latestStoredTelemetryProvider,
  );
  return latest.when(
    data: (TelemetryRecord? record) {
      if (record == null) {
        return TrackingServiceStatus.connecting;
      }

      final Duration age = Parsers.now().difference(record.recordedAt);
      if (age <= const Duration(hours: 24)) {
        return TrackingServiceStatus.ok;
      }
      return TrackingServiceStatus.failure;
    },
    loading: () => TrackingServiceStatus.connecting,
    error: (_, __) => TrackingServiceStatus.failure,
  );
});

final realtimeTrackingIndicatorProvider = Provider<TrackingIndicatorData>((
  Ref ref,
) {
  final TrackingServiceStatus status = ref.watch(
    realtimeTrackingStatusProvider,
  );
  return TrackingIndicatorData(
    kind: TrackingIndicatorKind.realtime,
    status: status,
    tooltip: switch (status) {
      TrackingServiceStatus.connecting => 'Conectando en tiempo real',
      TrackingServiceStatus.ok => 'Información en vivo',
      TrackingServiceStatus.failure =>
        'No está disponible la información en vivo',
    },
  );
});
