import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_position.dart';
import '../models/telemetry_record.dart';
import '../services/telemetry_database_service.dart';
import '../models/device_alert.dart';

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

final positionStreamProvider = StreamProvider<DevicePosition>((Ref ref) {
  final TelemetryDatabaseService service = ref.watch(
    telemetryDatabaseServiceProvider,
  );
  return _pollLatestPosition(ref, service);
});

final alertStreamProvider = StreamProvider<DeviceAlert>((Ref ref) async* {
  await for (final List<DeviceAlert> alerts in _watchFirestoreAlerts(ref)) {
    if (alerts.isNotEmpty) {
      yield alerts.first;
    }
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
const String _defaultAlertsCollection = 'device_alerts';

final alertsHistoryProvider = StreamProvider<List<DeviceAlert>>((Ref ref) {
  return _watchFirestoreAlerts(ref);
});

final alertsUnseenCountProvider = StreamProvider<int>((Ref ref) {
  return _pollFirestoreUnseenCount(ref);
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
  final Query<Map<String, dynamic>> query =
      FirebaseFirestore.instance.collection(collectionName).limit(300);

  String? lastSignature;
  await for (final QuerySnapshot<Map<String, dynamic>> snapshot
      in query.snapshots()) {
    final List<Map<String, dynamic>> allItems = snapshot.docs
        .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
          final Map<String, dynamic> data = Map<String, dynamic>.from(doc.data());
          data['id'] = doc.id;
          return data;
        })
        .toList(growable: false);

    final List<Map<String, dynamic>> sourceItems =
        deviceId.isEmpty
        ? allItems
        : allItems.where((Map<String, dynamic> item) {
            final String itemDeviceId = (item['device_id'] ?? '').toString();
            return itemDeviceId == deviceId;
          }).toList(growable: false);

    final List<Map<String, dynamic>> effectiveItems =
        sourceItems.isNotEmpty ? sourceItems : allItems;

    final List<DeviceAlert> alerts = effectiveItems
        .map(DeviceAlert.fromBackendJson)
        .whereType<DeviceAlert>()
        .toList(growable: false)
      ..sort((DeviceAlert a, DeviceAlert b) => b.timestamp.compareTo(a.timestamp));

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
          : alerts.where((DeviceAlert alert) => alert.timestamp.isAfter(seenAt)).length;

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
