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

final alertsHistoryProvider = FutureProvider<List<DeviceAlert>>((Ref ref) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) return const <DeviceAlert>[];

  try {
    final List<DeviceAlert> alerts = await ref
        .read(vercelConnectorServiceProvider)
        .getDeviceAlerts(deviceId, limit: 100);
    return _dedupeAlerts(alerts)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  } catch (_) {
    return const <DeviceAlert>[];
  }
});

final alertStreamProvider = StreamProvider<DeviceAlert>((Ref ref) async* {
  await for (final List<DeviceAlert> alerts in _pollBackendAlertsFallback(ref)) {
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
            if (alert.timestamp.isAfter(latest)) {
              latest = alert.timestamp;
            }
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
    data: (List<DeviceAlert> alerts) => alerts.where((DeviceAlert alert) {
      if (alert.checked) {
        return false;
      }
      if (seenCutoff == null) {
        return true;
      }
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
        .where((DeviceAlert alert) => !alert.checked)
        .where((DeviceAlert alert) => (alert.id ?? '').isNotEmpty)
        .toList(growable: false);

    if (unseen.isEmpty) {
      return;
    }

    final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
    if (deviceId.isNotEmpty) {
      try {
        await ref
            .read(vercelConnectorServiceProvider)
            .markAlertsChecked(
              deviceId,
              alertIds: unseen
                  .map((DeviceAlert alert) => alert.id!)
                  .toList(growable: false),
              limit: 300,
            );
        return;
      } catch (_) {
        // fallback to direct Firestore write if backend endpoint is unavailable
      }
    }

    final String collectionName =
        (dotenv.env['ALERTS_COLLECTION'] ?? '').trim().isEmpty
        ? _defaultAlertsCollection
        : (dotenv.env['ALERTS_COLLECTION'] ?? '').trim();
    final CollectionReference<Map<String, dynamic>> collection =
        FirebaseFirestore.instance.collection(collectionName);

    WriteBatch batch = FirebaseFirestore.instance.batch();
    int ops = 0;

    for (final DeviceAlert alert in unseen) {
      batch.update(collection.doc(alert.id!), <String, Object?>{
        'checked': true,
        'checked_at': FieldValue.serverTimestamp(),
      });
      ops += 1;

      if (ops >= 450) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
        ops = 0;
      }
    }

    if (ops > 0) {
      await batch.commit();
    }
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
  final int? numericDeviceId = int.tryParse(deviceId);

  final Query<Map<String, dynamic>> query;
  if (deviceId.isEmpty) {
    query = FirebaseFirestore.instance.collection(collectionName).limit(300);
  } else if (numericDeviceId != null) {
    query = FirebaseFirestore.instance
        .collection(collectionName)
        .where('device.id', whereIn: <Object>[deviceId, numericDeviceId])
        .limit(300);
  } else {
    query = FirebaseFirestore.instance
        .collection(collectionName)
        .where('device.id', isEqualTo: deviceId)
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

      // Only match by nested `device.id` — no legacy fallbacks
      final List<Map<String, dynamic>> sourceItems = deviceId.isEmpty
          ? allItems
          : allItems
                .where((Map<String, dynamic> item) {
                  final dynamic deviceField = item['device'];
                  final Object? rawId = (deviceField is Map) ? deviceField['id'] : null;
                  if (rawId == null) {
                    return false;
                  }

                  if (rawId is num && numericDeviceId != null) {
                    return rawId.toInt() == numericDeviceId;
                  }

                  return rawId.toString() == deviceId;
                })
                .toList(growable: false);

      final List<Map<String, dynamic>> effectiveItems = sourceItems.isNotEmpty
          ? sourceItems
          : allItems;

      final List<DeviceAlert> alerts = effectiveItems
          .map(DeviceAlert.fromBackendJson)
          .whereType<DeviceAlert>()
          .toList(growable: false);

      final List<DeviceAlert> deduped = _dedupeAlerts(alerts)
        ..sort(
          (DeviceAlert a, DeviceAlert b) => b.timestamp.compareTo(a.timestamp),
        );

      final List<DeviceAlert> limited = deduped.length <= 100
          ? deduped
          : deduped.sublist(0, 100);

      final String signature = limited
          .map(
            (DeviceAlert alert) =>
                '${alert.id ?? ''}:${alert.dedupeKey ?? ''}:${alert.checked}:${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}',
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
        final List<DeviceAlert> deduped = _dedupeAlerts(alerts);

        final String signature = deduped
            .map(
              (DeviceAlert alert) =>
                  '${alert.id ?? ''}:${alert.dedupeKey ?? ''}:${alert.checked}:${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}',
            )
            .join('|');

        if (signature != lastSignature) {
          lastSignature = signature;
          yield deduped;
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

List<DeviceAlert> _dedupeAlerts(List<DeviceAlert> alerts) {
  final Map<String, DeviceAlert> byKey = <String, DeviceAlert>{};

  for (final DeviceAlert alert in alerts) {
    final String key;
    if ((alert.id ?? '').isNotEmpty) {
      key = 'id:${alert.id}';
    } else if ((alert.dedupeKey ?? '').isNotEmpty) {
      key = 'dedupe:${alert.dedupeKey}';
    } else {
      key =
          'sig:${alert.type.name}:${alert.timestamp.toIso8601String()}:${alert.isEntering}:${alert.message}:${alert.geofenceName ?? ''}';
    }

    final DeviceAlert? existing = byKey[key];
    if (existing == null || alert.timestamp.isAfter(existing.timestamp)) {
      byKey[key] = alert;
    }
  }

  return byKey.values.toList(growable: false);
}
