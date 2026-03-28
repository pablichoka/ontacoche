import '../utils/parsers.dart';

class DevicePosition {
  const DevicePosition({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.speed,
    this.timestamp,
    this.batteryLevel,
  });

  final double latitude;
  final double longitude;
  final double? altitude;
  final double? speed;
  final DateTime? timestamp;
  final double? batteryLevel;

  factory DevicePosition.fromFlespiJson(Map<String, dynamic> json) {
    final Map<String, dynamic> payload = _unwrapPayload(json);
    final Map<String, dynamic>? nestedPosition = _asMap(payload['position']);

    final double? latitude = _readDouble(
      nestedPosition?['latitude'] ?? payload['latitude'] ?? payload['lat'],
    );
    final double? longitude = _readDouble(
      nestedPosition?['longitude'] ?? payload['longitude'] ?? payload['lng'] ?? payload['lon'],
    );

    if (latitude == null || longitude == null) {
      throw const FormatException('Latitude/longitude not found in Flespi payload');
    }

    return DevicePosition(
      latitude: latitude,
      longitude: longitude,
      altitude: _readDouble(nestedPosition?['altitude'] ?? payload['altitude']),
      speed: _readDouble(
        nestedPosition?['speed'] ?? payload['speed'] ?? payload['position.speed'],
      ),
      timestamp: _readDateTime(
        payload['source_ts'],
      ),
      batteryLevel: _readDouble(
        _asMap(payload['battery'])?['level'] ?? payload['battery.level'] ?? payload['battery_level'],
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'speed': speed,
      'timestamp': timestamp?.toIso8601String(),
      'battery.level': batteryLevel,
    };
  }

  static Map<String, dynamic> _unwrapPayload(Map<String, dynamic> json) {
    final dynamic result = json['result'];
    if (result is List && result.isNotEmpty && result.first is Map<String, dynamic>) {
      return Map<String, dynamic>.from(result.first as Map<String, dynamic>);
    }

    final Map<String, dynamic>? positionMap = _asMap(json['position']);
    if (positionMap != null &&
        positionMap.containsKey('latitude') &&
        positionMap.containsKey('longitude')) {
      return json;
    }

    return json;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }

    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }

    return null;
  }

  static double? readDouble(dynamic value) {
    if (value == null) {
      return null;
    }

    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value.toString());
  }

  static double? _readDouble(dynamic value) => readDouble(value);

  static DateTime? _readDateTime(dynamic value) {
    return Parsers.fromUnknown(value);
  }
}