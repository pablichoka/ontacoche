import 'dart:async';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_message.dart';
import '../models/device_position.dart';
import '../models/tracking_flow.dart';
import '../models/telemetry_record.dart';
import '../utils/parsers.dart';
import 'api_provider.dart';
import 'mqtt_provider.dart';
import 'telemetry_provider.dart';

final trackedDeviceIdProvider = Provider<String>((Ref ref) {
  return (dotenv.env['DEVICE_ID'] ?? '').trim();
});

final initialTrackingProvider = NotifierProvider<InitialTrackingController, InitialTrackingState>(
  InitialTrackingController.new,
);

class InitialTrackingController extends Notifier<InitialTrackingState> {
  bool _disposed = false;
  bool _initialized = false;

  @override
  InitialTrackingState build() {
    ref.onDispose(() {
      _disposed = true;
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

    unawaited(syncFromRemote());
  }

  Future<void> syncFromRemote() async {
    state = state.copyWith(
      status: TrackingServiceStatus.connecting,
      source: InitialTrackingSource.fallback,
      clearErrorMessage: true,
    );

    bool remoteUpdated = false;

    try {
      final String selector = ref.read(deviceSelectorProvider);
      final DevicePosition? telemetryPosition = await ref
          .read(flespiApiServiceProvider)
          .getCurrentPosition(selector);

      if (_disposed) {
        return;
      }

      DevicePosition? remotePosition = telemetryPosition;

      if (remotePosition == null) {
        final DeviceMessageSnapshot? latestMessage = await ref
            .read(flespiApiServiceProvider)
            .getLatestPositionMessage(selector);

        if (_disposed) {
          return;
        }

        if (latestMessage != null && latestMessage.hasCoordinates) {
          remotePosition = latestMessage.toDevicePosition();
        }
      }

      if (remotePosition != null) {
        final String deviceId = ref.read(trackedDeviceIdProvider);
        if (deviceId.isNotEmpty) {
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
      if (_disposed) {
        return;
      }

      state = state.copyWith(errorMessage: error.toString());
    }

    final TelemetryRecord? stored =
        await ref.read(telemetryDatabaseServiceProvider).fetchLatestRecord();
    if (_disposed) {
      return;
    }

    if (stored == null) {
      state = state.copyWith(
        status: TrackingServiceStatus.failure,
        source: InitialTrackingSource.fallback,
        errorMessage: state.errorMessage ?? 'No se encontró ninguna posición inicial',
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
      source: remoteUpdated ? InitialTrackingSource.remote : InitialTrackingSource.persisted,
      position: storedPosition,
      resolvedAt: stored.recordedAt,
      clearErrorMessage: true,
    );
  }
}

final initialTrackingIndicatorProvider = Provider<TrackingIndicatorData>((Ref ref) {
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

final realtimeTrackingStatusProvider = Provider<TrackingServiceStatus>((Ref ref) {
  final AsyncValue<DevicePosition> latestPosition = ref.watch(positionStreamProvider);
  return latestPosition.when(
    data: (DevicePosition position) {
      final DateTime? timestamp = position.timestamp;
      if (timestamp == null) {
        return TrackingServiceStatus.connecting;
      }

      final Duration age = Parsers.now().difference(timestamp);
      if (age <= const Duration(hours: 24)) {
        return TrackingServiceStatus.ok;
      }
      return TrackingServiceStatus.failure;
    },
    loading: () => TrackingServiceStatus.connecting,
    error: (_, __) => TrackingServiceStatus.failure,
  );
});

final realtimeTrackingIndicatorProvider = Provider<TrackingIndicatorData>((Ref ref) {
  final TrackingServiceStatus status = ref.watch(realtimeTrackingStatusProvider);
  return TrackingIndicatorData(
    kind: TrackingIndicatorKind.realtime,
    status: status,
    tooltip: switch (status) {
      TrackingServiceStatus.connecting => 'Conectando en tiempo real',
      TrackingServiceStatus.ok => 'Información en vivo',
      TrackingServiceStatus.failure => 'No está disponible la información en vivo',
    },
  );
});