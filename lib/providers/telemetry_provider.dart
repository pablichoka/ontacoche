import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/telemetry_record.dart';
import '../services/telemetry_database_service.dart';
import 'api_provider.dart';

final telemetryDatabaseServiceProvider = Provider<TelemetryDatabaseService>((
  Ref ref,
) {
  final TelemetryDatabaseService service = TelemetryDatabaseService();
  ref.onDispose(service.dispose);
  return service;
});

const Duration _databasePollInterval = Duration(seconds: 2);
const String _defaultAlertsCollection = 'device_alerts';

final telemetryHistoryProvider = StreamProvider<List<TelemetryRecord>>((
  Ref ref,
) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return _pollRecords(ref, service);
});

final positionStreamProvider = StreamProvider<DevicePosition>((Ref ref) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return _pollLatestPosition(ref, service);
});

final alertsHistoryProvider = StreamProvider<List<DeviceAlert>>((Ref ref) {
  return _watchFirestoreAlerts(ref);
});

final alertStreamProvider = StreamProvider<DeviceAlert>((Ref ref) async* {
  await for (final List<DeviceAlert> alerts in _watchFirestoreAlerts(ref)) {
    if (alerts.isNotEmpty) {
      yield alerts.first;
    }
  }
});

final latestStoredTelemetryProvider = FutureProvider<TelemetryRecord?>(
  (Ref ref) {
    final TelemetryDatabaseService service = ref.watch(
      telemetryDatabaseServiceProvider,
    );
    return service.fetchLatestRecord();
  },
);

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
      };
    });

final _alertsSeenAtProvider = StateProvider<DateTime?>((Ref ref) => null);

final alertsUnseenCountProvider = StreamProvider<int>((Ref ref) {
  return _pollFirestoreUnseenCount(ref);
});

final markAllAlertsSeenUseCaseProvider = Provider<Future<void> Function()>(
  (Ref ref) {
    return () async {
      ref.read(_alertsSeenAtProvider.notifier).state = DateTime.now();
    };
  },
);

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

Stream<DevicePosition> _pollLatestPosition(
  Ref ref,
  TelemetryDatabaseService service,
) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  String? lastSignature;
  while (!disposed) {
    final TelemetryRecord? record = await service.fetchLatestRecord();
    if (record != null) {
      final String signature =
          '${record.id}:${record.recordedAt.toIso8601String()}';
      if (signature != lastSignature) {
        lastSignature = signature;
        yield DevicePosition(
          latitude: record.latitude,
          longitude: record.longitude,
          altitude: record.altitude,
          speed: record.speed,
          timestamp: record.recordedAt,
          batteryLevel: record.batteryLevel,
        );
      }
    }

    await Future<void>.delayed(_databasePollInterval);
  }
}

Stream<List<DeviceAlert>> _watchFirestoreAlerts(Ref ref) async* {
  final String collectionName =
      (dotenv.env['ALERTS_COLLECTION'] ?? '').trim().isEmpty
      ? _defaultAlertsCollection
      : (dotenv.env['ALERTS_COLLECTION'] ?? '').trim();
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  final int? numericDeviceId = int.tryParse(deviceId);

  final Query<Map<String, dynamic>> query;
  if (deviceId.isEmpty) {
    query = FirebaseFirestore.instance.collection(collectionName).limit(300);
  } else if (numericDeviceId != null) {
    query = FirebaseFirestore.instance
        .collection(collectionName)
        .where('device_id', whereIn: <Object>[deviceId, numericDeviceId])
        .limit(300);
  } else {
    query = FirebaseFirestore.instance
        .collection(collectionName)
        .where('device_id', isEqualTo: deviceId)
        .limit(300);
  }

  String? lastSignature;

  try {
    await for (final QuerySnapshot<Map<String, dynamic>> snapshot
        in query.snapshots()) {
      final List<Map<String, dynamic>> allItems = snapshot.docs
          .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
            final Map<String, dynamic> data = Map<String, dynamic>.from(
              doc.data(),
            );
            data['id'] = doc.id;
            return data;
          })
          .toList(growable: false);

      final List<Map<String, dynamic>> sourceItems = deviceId.isEmpty
          ? allItems
          : allItems.where((Map<String, dynamic> item) {
              final Object? rawId = item['device_id'];
              if (rawId == null) {
                return false;
              }

              if (rawId is num && numericDeviceId != null) {
                return rawId.toInt() == numericDeviceId;
              }

              return rawId.toString() == deviceId;
            }).toList(growable: false);

      final List<Map<String, dynamic>> effectiveItems =
          sourceItems.isNotEmpty ? sourceItems : allItems;

      final List<DeviceAlert> alerts = effectiveItems
          .map(DeviceAlert.fromBackendJson)
          .whereType<DeviceAlert>()
          .toList(growable: false)
        ..sort(
          (DeviceAlert a, DeviceAlert b) => b.timestamp.compareTo(a.timestamp),
        );

      final List<DeviceAlert> limited = alerts.length <= 100
          ? alerts
          : alerts.sublist(0, 100);

      final String signature = limited
          .map(
            (DeviceAlert alert) =>
                '${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}',
          )
          .join('|');

      if (signature != lastSignature) {
        lastSignature = signature;
        yield limited;
      }
    }
  } catch (_) {
    yield* _pollBackendAlertsFallback(ref);
  }
}

Stream<List<DeviceAlert>> _pollBackendAlertsFallback(Ref ref) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  const Duration pollInterval = Duration(seconds: 15);
  String? lastSignature;

  while (!disposed) {
    try {
      final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
      if (deviceId.isNotEmpty) {
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

Stream<int> _pollFirestoreUnseenCount(Ref ref) async* {
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
  });

  const Duration pollInterval = Duration(seconds: 3);
  int? lastCount;

  while (!disposed) {
    try {
      final List<DeviceAlert> alerts = await ref.read(alertsHistoryProvider.future);
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
    } catch (_) {
      if (lastCount != 0) {
        lastCount = 0;
        yield 0;
      }
    }

    await Future<void>.delayed(pollInterval);
  }
}
