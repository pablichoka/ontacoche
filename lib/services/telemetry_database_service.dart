import 'dart:async';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/telemetry_record.dart';
import '../models/device_alert.dart';
import '../utils/parsers.dart';

class TelemetryDatabaseService {
  TelemetryDatabaseService({this.retentionDays = 30, this.historyLimit = 100});

  final int retentionDays;
  final int historyLimit;

  Database? _database;
  Future<Database>? _openingDatabase;
  final StreamController<List<TelemetryRecord>> _historyController =
      StreamController<List<TelemetryRecord>>.broadcast();
  final StreamController<List<DeviceAlert>> _alertsController =
      StreamController<List<DeviceAlert>>.broadcast();
  final StreamController<int> _unseenController =
      StreamController<int>.broadcast();

  Stream<List<TelemetryRecord>> watchRecentRecords() async* {
    yield await fetchRecentRecords(limit: historyLimit);
    yield* _historyController.stream;
  }

  Future<TelemetryRecord?> fetchLatestRecord() async {
    final List<TelemetryRecord> records = await fetchRecentRecords(limit: 1);
    if (records.isEmpty) {
      return null;
    }
    return records.first;
  }

  Future<void> insertRecord(TelemetryRecord record) async {
    final Database database = await _openDatabase();
    final List<Map<String, Object?>> existing = await database.query(
      'telemetry_records',
      columns: <String>['id'],
      where: 'device_id = ? AND recorded_at = ?',
      whereArgs: <Object>[
        record.deviceId,
        record.recordedAt.toUtc().toIso8601String(),
      ],
      limit: 1,
    );

    if (existing.isEmpty) {
      await database.insert('telemetry_records', record.toMap());
    } else {
      await database.update(
        'telemetry_records',
        record.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: <Object>[existing.first['id'] as int],
      );
    }

    await _cleanupOldRecords(database);
    await _publishRecentRecords(database);
  }

  Future<bool> insertAlert(
    DeviceAlert alert, {
    required String deviceId,
  }) async {
    final Database database = await _openDatabase();

    // deduplicate alerts inside a short window while preserving geofence edges
    final String typeStr = alert.type.toString().split('.').last;
    final DateTime windowStart = alert.timestamp.subtract(
      const Duration(seconds: 30),
    );
    final DateTime windowEnd = alert.timestamp.add(const Duration(seconds: 30));
    final List<String> whereClauses = <String>[
      'type = ?',
      'timestamp >= ?',
      'timestamp <= ?',
    ];
    final List<Object> whereArgs = <Object>[
      typeStr,
      windowStart.toIso8601String(),
      windowEnd.toIso8601String(),
    ];

    if (alert.type == DeviceAlertType.geofence) {
      whereClauses.add('COALESCE(geofence_name, "") = ?');
      whereArgs.add(alert.geofenceName ?? '');
      whereClauses.add('COALESCE(is_entering, -1) = ?');
      whereArgs.add(
        alert.isEntering == null ? -1 : (alert.isEntering! ? 1 : 0),
      );
    }

    final List<Map<String, Object?>> existing = await database.query(
      'alerts',
      columns: <String>['id'],
      where: whereClauses.join(' AND '),
      whereArgs: whereArgs,
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return false;
    }

    await database.insert('alerts', <String, Object?>{
      'device_id': deviceId,
      'type': alert.type.toString().split('.').last,
      'message': alert.message,
      'value': alert.value?.toString(),
      'geofence_name': alert.geofenceName,
      'is_entering': alert.isEntering == null
          ? null
          : (alert.isEntering! ? 1 : 0),
      'seen': 0,
      'timestamp': alert.timestamp.toIso8601String(),
      'created_at': Parsers.now().toIso8601String(),
    });
    await _cleanupOldAlerts(database);
    await _publishRecentAlerts(database);
    await _publishUnseenCount(database);
    return true;
  }

  Stream<List<DeviceAlert>> watchRecentAlerts() async* {
    try {
      yield await fetchRecentAlerts(limit: historyLimit);
    } catch (_) {
      yield const <DeviceAlert>[];
    }
    yield* _alertsController.stream;
  }

  Future<List<DeviceAlert>> fetchRecentAlerts({int limit = 50}) async {
    final Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.query(
      'alerts',
      orderBy: 'created_at DESC, timestamp DESC',
      limit: limit,
    );

    return rows.map(_deviceAlertFromMap).toList(growable: false);
  }

  Future<int> fetchUnseenCount() async {
    final Database database = await _openDatabase();
    return _fetchUnseenCount(database);
  }

  Stream<int> watchUnseenCount() async* {
    try {
      yield await fetchUnseenCount();
    } catch (_) {
      yield 0;
    }
    yield* _unseenController.stream;
  }

  Future<void> markAllAlertsSeen() async {
    final Database database = await _openDatabase();
    await database.update('alerts', <String, Object?>{
      'seen': 1,
    }, where: 'seen = 0');
    await _publishUnseenCount(database);
    await _publishRecentAlerts(database);
  }

  Future<void> _publishUnseenCount(Database database) async {
    if (_unseenController.isClosed) return;
    final int count = await _fetchUnseenCount(database);
    _unseenController.add(count);
  }

  Future<int> _fetchUnseenCount(Database database) async {
    final List<Map<String, Object?>> rows = await database.rawQuery(
      'SELECT COUNT(*) AS total FROM alerts WHERE seen = 0',
    );
    final Object? total = rows.first['total'];
    return total is int ? total : int.parse(total.toString());
  }

  DeviceAlert _deviceAlertFromMap(Map<String, Object?> map) {
    final String typeStr = (map['type'] as String?) ?? 'unknown';
    DeviceAlertType type;
    switch (typeStr) {
      case 'geofence':
        type = DeviceAlertType.geofence;
        break;
      case 'vibration':
        type = DeviceAlertType.vibration;
        break;
      case 'lowBattery':
        type = DeviceAlertType.lowBattery;
        break;
      case 'movement':
        type = DeviceAlertType.movement;
        break;
      default:
        type = DeviceAlertType.unknown;
    }

    final String message = (map['message'] as String?) ?? '';
    final String? geofenceName = map['geofence_name'] as String?;
    final int? isEnteringInt = map['is_entering'] as int?;
    final bool? isEntering = isEnteringInt == null ? null : isEnteringInt == 1;
    final int seen = ((map['seen'] as int?) ?? 0);
    final String timestampStr =
        (map['timestamp'] as String?) ?? Parsers.now().toIso8601String();
    final String createdAtStr = (map['created_at'] as String?) ?? timestampStr;
    final DateTime sourceTs = DateTime.parse(timestampStr);
    final DateTime createdAt = DateTime.parse(createdAtStr);
    final DateTime ts = createdAt.isAfter(sourceTs) ? createdAt : sourceTs;

    return DeviceAlert(
      id: map['id']?.toString(),
      type: type,
      message: message,
      timestamp: ts,
      value: map['value'],
      geofenceName: geofenceName,
      isEntering: isEntering,
      checked: seen == 0,
    );
  }

  Future<List<TelemetryRecord>> fetchRecentRecords({int limit = 20}) async {
    final Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.query(
      'telemetry_records',
      orderBy: 'recorded_at DESC',
      limit: limit,
    );

    return rows.map(TelemetryRecord.fromMap).toList(growable: false);
  }

  Future<int> countRecords() async {
    final Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.rawQuery(
      'SELECT COUNT(*) AS total FROM telemetry_records',
    );

    final Object? total = rows.first['total'];
    return total is int ? total : int.parse(total.toString());
  }

  Future<void> dispose() async {
    await _historyController.close();
    await _alertsController.close();
    await _unseenController.close();
    final Database? database = _database;
    _database = null;
    _openingDatabase = null;
    await database?.close();
  }

  Future<Database> _openDatabase() {
    final Database? existing = _database;
    if (existing != null) {
      return Future<Database>.value(existing);
    }

    final Future<Database>? pending = _openingDatabase;
    if (pending != null) {
      return pending;
    }

    final Future<Database> opening = _createDatabase();
    _openingDatabase = opening;
    return opening;
  }

  Future<Database> _createDatabase() async {
    final String databasesPath = await getDatabasesPath();
    final String databasePath = path.join(
      databasesPath,
      'ontacoche_telemetry.db',
    );

    final Database database = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE telemetry_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude REAL,
            speed REAL,
            battery_level REAL,
            recorded_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_telemetry_records_recorded_at ON telemetry_records(recorded_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_telemetry_records_device_id ON telemetry_records(device_id)',
        );
        await db.execute('''
          CREATE TABLE alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            type TEXT NOT NULL,
            message TEXT NOT NULL,
            value TEXT,
            geofence_name TEXT,
            is_entering INTEGER,
            seen INTEGER NOT NULL DEFAULT 0,
            timestamp TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_alerts_timestamp ON alerts(timestamp DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_alerts_device_id ON alerts(device_id)',
        );
      },
      onOpen: (Database db) async {
        // Ensure alerts table exists for upgrades / existing DBs
        await db.execute('''
          CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            type TEXT NOT NULL,
            message TEXT NOT NULL,
            value TEXT,
            geofence_name TEXT,
            is_entering INTEGER,
            seen INTEGER NOT NULL DEFAULT 0,
            timestamp TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_alerts_timestamp ON alerts(timestamp DESC)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_alerts_device_id ON alerts(device_id)',
        );
        // Ensure 'seen' column exists on older DBs; add it if missing
        try {
          final List<Map<String, Object?>> info = await db.rawQuery(
            'PRAGMA table_info(alerts)',
          );
          final bool hasSeen = info.any(
            (Map<String, Object?> row) => (row['name'] as String?) == 'seen',
          );
          if (!hasSeen) {
            await db.execute(
              'ALTER TABLE alerts ADD COLUMN seen INTEGER NOT NULL DEFAULT 0',
            );
          }
        } catch (_) {
          // Ignore migration failures; table may not exist yet or PRAGMA unsupported on platform
        }
        // Publish initial unseen count if any listeners exist
        try {
          await _publishUnseenCount(db);
        } catch (_) {
          // ignore
        }
      },
    );

    _database = database;
    _openingDatabase = null;
    return database;
  }

  Future<void> _cleanupOldRecords(Database database) async {
    final DateTime cutoff = DateTime.now().toUtc().subtract(
      Duration(days: retentionDays),
    );
    await database.delete(
      'telemetry_records',
      where: 'recorded_at < ?',
      whereArgs: <Object>[cutoff.toIso8601String()],
    );
  }

  Future<void> _cleanupOldAlerts(Database database) async {
    final DateTime cutoff = DateTime.now().toUtc().subtract(
      Duration(days: retentionDays),
    );
    await database.delete(
      'alerts',
      where: 'timestamp < ?',
      whereArgs: <Object>[cutoff.toIso8601String()],
    );
    await _publishUnseenCount(database);
  }

  Future<void> _publishRecentRecords(Database database) async {
    if (_historyController.isClosed) {
      return;
    }

    final List<Map<String, Object?>> rows = await database.query(
      'telemetry_records',
      orderBy: 'recorded_at DESC',
      limit: historyLimit,
    );

    _historyController.add(
      rows.map(TelemetryRecord.fromMap).toList(growable: false),
    );
  }

  Future<void> _publishRecentAlerts(Database database) async {
    if (_alertsController.isClosed) {
      return;
    }

    final List<Map<String, Object?>> rows = await database.query(
      'alerts',
      orderBy: 'created_at DESC, timestamp DESC',
      limit: historyLimit,
    );

    _alertsController.add(
      rows.map(_deviceAlertFromMap).toList(growable: false),
    );
  }
}
