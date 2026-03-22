import 'device_position.dart';
import '../utils/parsers.dart';

enum DeviceMessageKind {
  heartbeat,
  position,
  unknown,
}

class DeviceMessageSnapshot {
  const DeviceMessageSnapshot({
    required this.reportCode,
    required this.timestamp,
    required this.serverTimestamp,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.speed,
    this.batteryLevel,
    this.batteryVoltage,
    this.geofenceStatus,
    this.geofenceName,
  });

  final String? reportCode;
  final DateTime? timestamp;
  final DateTime? serverTimestamp;
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final double? speed;
  final double? batteryLevel;
  final double? batteryVoltage;
  final bool? geofenceStatus;
  final String? geofenceName;

  DateTime? get occurredAt => serverTimestamp ?? timestamp;

  bool get hasCoordinates => latitude != null && longitude != null;

  DeviceMessageKind get kind {
    if (hasCoordinates) {
      return DeviceMessageKind.position;
    }
    if (reportCode == '0100' || reportCode == '0102') {
      return DeviceMessageKind.heartbeat;
    }
    return DeviceMessageKind.unknown;
  }

  DevicePosition toDevicePosition() {
    if (!hasCoordinates) {
      throw const FormatException('Device message does not contain coordinates');
    }

    return DevicePosition(
      latitude: latitude!,
      longitude: longitude!,
      altitude: altitude,
      speed: speed,
      batteryLevel: batteryLevel,
      timestamp: occurredAt,
    );
  }

  factory DeviceMessageSnapshot.fromJson(Map<String, dynamic> json) {
    return DeviceMessageSnapshot(
      reportCode: json['report.code']?.toString(),
      timestamp: _readDateTime(json['timestamp']),
      serverTimestamp: _readDateTime(json['server.timestamp']),
      latitude: DevicePosition.readDouble(json['position.latitude']),
      longitude: DevicePosition.readDouble(json['position.longitude']),
      altitude: DevicePosition.readDouble(json['position.altitude']),
      speed: DevicePosition.readDouble(json['position.speed']),
      batteryLevel: DevicePosition.readDouble(json['battery.level']),
      batteryVoltage: DevicePosition.readDouble(json['battery.voltage']),
      geofenceStatus: _readBool(json['plugin.geofence.status']),
      geofenceName: _readString(json['plugin.geofence.name']),
    );
  }

  static DateTime? _readDateTime(Object? value) {
    return Parsers.fromUnknown(value);
  }

  static bool? _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
  }

  static String? _readString(Object? value) {
    final String? parsed = value?.toString().trim();
    if (parsed == null || parsed.isEmpty) {
      return null;
    }
    return parsed;
  }
}