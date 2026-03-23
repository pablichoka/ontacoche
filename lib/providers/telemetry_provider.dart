import 'dart:async';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_position.dart';
import '../models/telemetry_record.dart';
import '../services/telemetry_database_service.dart';
import '../models/device_alert.dart';
import 'api_provider.dart';

final telemetryDatabaseServiceProvider = Provider<TelemetryDatabaseService>((
  Ref ref,
) {
  final TelemetryDatabaseService service = TelemetryDatabaseService();
  ref.onDispose(service.dispose);
  return service;
});

const Duration _databasePollInterval = Duration(seconds: 2);

final telemetryHistoryProvider = StreamProvider<List<TelemetryRecord>>((
  Ref ref,
) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return _pollRecords(ref, service);
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
        if (deviceId.isEmpty) {
          return;
        }

        final TelemetryRecord record = TelemetryRecord.fromDevicePosition(
          deviceId: deviceId,
          position: position,
        );
        await service.insertRecord(record);
        ref.invalidate(latestStoredTelemetryProvider);
        ref.invalidate(telemetryCountProvider);
      };
    });

final persistAlertUseCaseProvider =
    Provider<Future<void> Function(DeviceAlert)>((Ref ref) {
      final TelemetryDatabaseService service = ref.watch(
        telemetryDatabaseServiceProvider,
      );
      final String deviceId = dotenv.env['DEVICE_ID'] ?? '';

      return (DeviceAlert alert) async {
        if (deviceId.isEmpty) {
          return;
        }
        await service.insertAlert(alert, deviceId: deviceId);
        // updates propagate via DB stream controllers — no invalidate needed
      };
    });

final _alertsSeenAtProvider = StateProvider<DateTime?>((Ref ref) => null);

final alertsHistoryProvider = StreamProvider<List<DeviceAlert>>((Ref ref) {
  return _pollBackendAlerts(ref);
});

final alertsUnseenCountProvider = StreamProvider<int>((Ref ref) {
  return _pollBackendUnseenCount(ref);
});

final markAllAlertsSeenUseCaseProvider = Provider<Future<void> Function()>((
  Ref ref,
) {
  return () async {
    ref.read(_alertsSeenAtProvider.notifier).state = DateTime.now();
  };
});

Stream<List<TelemetryRecord>> _pollRecords(
  Ref ref,
  TelemetryDatabaseService service,
) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  String? lastSignature;
  while (!disposed) {
    final List<TelemetryRecord> records = await service.fetchRecentRecords();
    final String signature = records
        .map(
          (TelemetryRecord record) =>
              '${record.id}:${record.recordedAt.toIso8601String()}',
        )
        .join('|');

    if (signature != lastSignature) {
      lastSignature = signature;
      yield records;
    }

    await Future<void>.delayed(_databasePollInterval);
  }
}

Stream<List<DeviceAlert>> _pollBackendAlerts(Ref ref) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  const Duration pollInterval = Duration(seconds: 15);
  String? lastSignature;
  while (!disposed) {
    try {
      final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
      if (deviceId.isEmpty) {
        if (lastSignature != '') {
          lastSignature = '';
          yield const <DeviceAlert>[];
        }
      } else {
        final List<DeviceAlert> alerts = await ref
            .read(vercelConnectorServiceProvider)
            .getDeviceAlerts(deviceId, limit: 100);

        final String signature = alerts
            .map(
              (DeviceAlert alert) =>
                  '${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}',
            )
            .join('|');

        if (signature != lastSignature) {
          lastSignature = signature;
          yield alerts;
        }
      }
    } catch (_) {
      if (lastSignature != '') {
        lastSignature = '';
        yield const <DeviceAlert>[];
      }
    }

    await Future<void>.delayed(pollInterval);
  }
}

Stream<int> _pollBackendUnseenCount(Ref ref) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  const Duration pollInterval = Duration(seconds: 15);
  int? lastCount;
  while (!disposed) {
    try {
      final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
      if (deviceId.isEmpty) {
        if (lastCount != 0) {
          lastCount = 0;
          yield 0;
        }
      } else {
        final List<DeviceAlert> alerts = await ref
            .read(vercelConnectorServiceProvider)
            .getDeviceAlerts(deviceId, limit: 100);
        final DateTime? seenAt = ref.read(_alertsSeenAtProvider);

        final int count = seenAt == null
            ? alerts.length
            : alerts
                  .where((DeviceAlert alert) => alert.timestamp.isAfter(seenAt))
                  .length;

        if (count != lastCount) {
          lastCount = count;
          yield count;
        }
      }
    } catch (_) {
      if (lastCount != 0) {
        lastCount = 0;
        yield 0;
      }
    }

    await Future<void>.delayed(pollInterval);
  }
}
