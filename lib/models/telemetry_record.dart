import 'device_position.dart';

class TelemetryRecord {
  const TelemetryRecord({
    this.id,
    required this.deviceId,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.speed,
    this.batteryLevel,
    required this.recordedAt,
    required this.createdAt,
    this.synced = false,
  });

  final int? id;
  final String deviceId;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? speed;
  final double? batteryLevel;
  final DateTime recordedAt;
  final DateTime createdAt;
  final bool synced;

  factory TelemetryRecord.fromDevicePosition({
    required String deviceId,
    required DevicePosition position,
    DateTime? createdAt,
  }) {
    final DateTime now = createdAt ?? DateTime.now().toUtc();

    return TelemetryRecord(
      deviceId: deviceId,
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      speed: position.speed,
      batteryLevel: position.batteryLevel,
      recordedAt: (position.timestamp ?? now).toUtc(),
      createdAt: now,
    );
  }

  factory TelemetryRecord.fromMap(Map<String, Object?> map) {
    return TelemetryRecord(
      id: map['id'] as int?,
      deviceId: map['device_id'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      batteryLevel: (map['battery_level'] as num?)?.toDouble(),
      recordedAt: DateTime.parse(map['recorded_at'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      synced: (map['synced'] as int? ?? 0) == 1,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'device_id': deviceId,
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'speed': speed,
      'battery_level': batteryLevel,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
      'synced': synced ? 1 : 0,
    };
  }
}
