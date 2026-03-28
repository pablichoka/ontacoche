import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/telemetry_record.dart';
import '../models/tracking_flow.dart';
import '../services/telemetry_database_service.dart';
import '../utils/parsers.dart';
import 'api_provider.dart';

// ----------------------------------------------------------------------
// Telemetry Database
// ----------------------------------------------------------------------

final telemetryDatabaseServiceProvider = Provider<TelemetryDatabaseService>((
  Ref ref,
) {
  final TelemetryDatabaseService service = TelemetryDatabaseService();
  ref.onDispose(service.dispose);
  return service;
});

// ----------------------------------------------------------------------
// Core Tracking: The single source of truth for device state
// ----------------------------------------------------------------------

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
    if (_disposed) return;
    _bindRealtimeDeviceState();

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_remoteSyncInterval, (_) {
      if (_disposed) return;
      syncFromRemote();
    });

    syncFromRemote();
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
          .where('device.id', isEqualTo: configuredDeviceId)
          .limit(1);
    }

    _deviceStateSubscription?.cancel();
    _deviceStateSubscription = query.snapshots().listen(
      (QuerySnapshot<Map<String, dynamic>> snapshot) {
        if (_disposed || snapshot.docs.isEmpty) return;
        DocumentSnapshot<Map<String, dynamic>> selected = snapshot.docs.first;

        final Map<String, dynamic>? selectedData = selected.data();
        final String resolvedDeviceId = configuredDeviceId.isNotEmpty
            ? configuredDeviceId
            : ((selectedData != null &&
                      selectedData['device'] is Map &&
                      (selectedData['device']['id'] ?? '')
                          .toString()
                          .isNotEmpty)
                  ? selectedData['device']['id'].toString()
                  : selected.id);

        _handleRealtimeSnapshot(selected, resolvedDeviceId);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_disposed) return;
        state = state.copyWith(errorMessage: 'Realtime listener error: $error');
      },
    );
  }

  Future<void> _handleRealtimeSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
    String deviceId,
  ) async {
    if (_disposed || !snapshot.exists) return;

    final Map<String, dynamic>? data = snapshot.data();
    if (data == null) return;

    final DevicePosition? realtimePosition = _positionFromStateDocument(data);
    if (realtimePosition == null) return;

    final String signature =
        '${data['source_ts'] ?? ''}'
        '|${realtimePosition.latitude}|${realtimePosition.longitude}|${realtimePosition.speed ?? ''}';

    // Deduplication using distinct identity
    if (_lastRealtimeSignature == signature) return;
    _lastRealtimeSignature = signature;

    final DateTime eventTimestamp = realtimePosition.timestamp ?? Parsers.now();
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
    if (_disposed) return;

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

    if (resolvedLatitude == null || resolvedLongitude == null) return null;

    final DateTime? timestamp = Parsers.fromUnknown(stateData['source_ts']);

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
      batteryLevel: DevicePosition.readDouble(_asBatteryLevel(stateData)),
    );
  }

  static dynamic _asBatteryLevel(Map<String, dynamic> stateData) {
    final dynamic battery = stateData['battery'];
    if (battery is Map) {
      return battery['level'] ?? battery['level'];
    }
    return stateData['battery_level'] ?? stateData['battery.level'];
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

      if (_disposed) return;

      if (remotePosition != null) {
        if (_lastRealtimeTimestamp != null &&
            remotePosition.timestamp != null &&
            !remotePosition.timestamp!.isAfter(_lastRealtimeTimestamp!)) {
          remotePosition = null;
        }

        if (deviceId.isNotEmpty && remotePosition != null) {
          final TelemetryRecord record = TelemetryRecord.fromDevicePosition(
            deviceId: deviceId,
            position: remotePosition,
          );
          await ref.read(telemetryDatabaseServiceProvider).insertRecord(record);
          ref.invalidate(latestStoredTelemetryProvider);
          ref.invalidate(telemetryCountProvider);
          remoteUpdated = true;
        }
      }
    } catch (error) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: error.toString());
    }

    final TelemetryRecord? stored = await ref
        .read(telemetryDatabaseServiceProvider)
        .fetchLatestRecord();
    if (_disposed) return;

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

// ----------------------------------------------------------------------
// Position and Telemetry Selectors
// ----------------------------------------------------------------------

final positionStreamProvider = StreamProvider<DevicePosition>((Ref ref) async* {
  final state = ref.watch(initialTrackingProvider);
  if (state.hasPosition && state.position != null) {
    yield state.position!;
  }
});

final telemetryHistoryProvider = StreamProvider<List<TelemetryRecord>>((
  Ref ref,
) async* {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  bool disposed = false;
  ref.onDispose(() => disposed = true);

  String? lastSignature;
  while (!disposed) {
    final List<TelemetryRecord> records = await service.fetchRecentRecords();
    final String signature = records
        .map((r) => '${r.id}:${r.recordedAt.toIso8601String()}')
        .join('|');

    if (signature != lastSignature) {
      lastSignature = signature;
      yield records;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

final latestStoredTelemetryProvider = FutureProvider<TelemetryRecord?>((
  Ref ref,
) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return service.fetchLatestRecord();
});

final telemetryCountProvider = FutureProvider<int>((Ref ref) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return service.countRecords();
});

final persistTelemetryUseCaseProvider =
    Provider<Future<void> Function(DevicePosition)>((Ref ref) {
      final TelemetryDatabaseService service = ref.watch(
        telemetryDatabaseServiceProvider,
      );
      final String deviceId = dotenv.env['DEVICE_ID'] ?? '';

      return (DevicePosition position) async {
        if (deviceId.isEmpty) return;
        final TelemetryRecord record = TelemetryRecord.fromDevicePosition(
          deviceId: deviceId,
          position: position,
        );
        await service.insertRecord(record);
        ref.invalidate(latestStoredTelemetryProvider);
        ref.invalidate(telemetryCountProvider);
      };
    });

// ----------------------------------------------------------------------
// UI Indicators
// ----------------------------------------------------------------------

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
      if (record == null) return TrackingServiceStatus.connecting;
      final Duration age = Parsers.now().difference(record.recordedAt);
      if (age <= const Duration(hours: 24)) return TrackingServiceStatus.ok;
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

// ----------------------------------------------------------------------
// Alerts Providers
// ----------------------------------------------------------------------

final alertsHistoryProvider = FutureProvider<List<DeviceAlert>>((
  Ref ref,
) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) return const <DeviceAlert>[];

  try {
    final List<DeviceAlert> alerts = await ref
        .read(vercelConnectorServiceProvider)
        .getDeviceAlerts(deviceId, limit: 100);
    final byKey = <String, DeviceAlert>{};
    for (final alert in alerts) {
      final key = alert.id?.isNotEmpty == true
          ? 'id:${alert.id}'
          : alert.dedupeKey?.isNotEmpty == true
          ? 'dedupe:${alert.dedupeKey}'
          : 'sig:${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}';
      final existing = byKey[key];
      if (existing == null || alert.timestamp.isAfter(existing.timestamp)) {
        byKey[key] = alert;
      }
    }
    return byKey.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  } catch (_) {
    return const <DeviceAlert>[];
  }
});

final alertStreamProvider = StreamProvider<DeviceAlert>((Ref ref) async* {
  bool disposed = false;
  ref.onDispose(() => disposed = true);

  String? lastSignature;
  while (!disposed) {
    try {
      final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
      if (deviceId.isNotEmpty) {
        final List<DeviceAlert> alerts = await ref
            .read(vercelConnectorServiceProvider)
            .getDeviceAlerts(deviceId, limit: 100);
        if (alerts.isNotEmpty) {
          final DeviceAlert first = alerts.first;
          final signature =
              '${first.id ?? ''}:${first.dedupeKey ?? ''}:${first.timestamp.toIso8601String()}';
          if (signature != lastSignature) {
            lastSignature = signature;
            yield first;
          }
        }
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});

final persistAlertUseCaseProvider =
    Provider<Future<void> Function(DeviceAlert)>((Ref ref) {
      final TelemetryDatabaseService service = ref.watch(
        telemetryDatabaseServiceProvider,
      );
      final String deviceId = dotenv.env['DEVICE_ID'] ?? '';

      return (DeviceAlert alert) async {
        if (deviceId.isEmpty) return;
        await service.insertAlert(alert, deviceId: deviceId);
      };
    });

final alertsSeenCutoffProvider = StateProvider<DateTime?>((Ref ref) => null);

final acknowledgeAlertsViewUseCaseProvider =
    Provider<void Function(List<DeviceAlert>)>((Ref ref) {
      return (List<DeviceAlert> alerts) {
        DateTime cutoff = DateTime.now();
        if (alerts.isNotEmpty) {
          DateTime latest = alerts.first.timestamp;
          for (final DeviceAlert alert in alerts) {
            if (alert.timestamp.isAfter(latest)) latest = alert.timestamp;
          }
          cutoff = latest.add(const Duration(milliseconds: 1));
        }
        ref.read(alertsSeenCutoffProvider.notifier).state = cutoff;
      };
    });

final alertsUnseenCountProvider = Provider<int>((Ref ref) {
  final AsyncValue<List<DeviceAlert>> alertsState = ref.watch(
    alertsHistoryProvider,
  );
  final DateTime? seenCutoff = ref.watch(alertsSeenCutoffProvider);

  return alertsState.maybeWhen(
    data: (alerts) => alerts.where((alert) {
      if (alert.checked) return false;
      if (seenCutoff == null) return true;
      return alert.timestamp.isAfter(seenCutoff);
    }).length,
    orElse: () => 0,
  );
});

final markAllAlertsSeenUseCaseProvider = Provider<Future<void> Function()>((
  Ref ref,
) {
  return () async {
    final List<DeviceAlert> alerts = await ref.read(
      alertsHistoryProvider.future,
    );
    final List<DeviceAlert> unseen = alerts
        .where((alert) => !alert.checked)
        .where((alert) => (alert.id ?? '').isNotEmpty)
        .toList();

    if (unseen.isEmpty) return;

    final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
    if (deviceId.isEmpty) return;

    try {
      await ref
          .read(vercelConnectorServiceProvider)
          .markAlertsChecked(
            deviceId,
            alertIds: unseen.map((a) => a.id!).toList(),
            limit: 300,
          );
    } catch (_) {}
  };
});
