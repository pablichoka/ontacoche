import '../utils/parsers.dart';

class RoutePoint {
  const RoutePoint({
    required this.lat,
    required this.lng,
    required this.speed,
    required this.timestamp,
  });

  final double lat;
  final double lng;
  final double speed;
  final DateTime timestamp;

  factory RoutePoint.fromJson(Map<String, dynamic> map) {
    return RoutePoint(
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
      speed: (map['speed'] as num? ?? 0).toDouble(),
      timestamp: Parsers.fromUnknown(map['timestamp']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lat': lat,
    'lng': lng,
    'speed': speed,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };
}

class Trip {
  const Trip({
    required this.id,
    required this.deviceIdent,
    required this.startTime,
    required this.endTime,
    this.activeDurationMinutes,
    required this.routePoints,
  });

  final String id;
  final String deviceIdent;
  final DateTime startTime;
  final DateTime endTime;
  final int? activeDurationMinutes;
  final List<RoutePoint> routePoints;

  factory Trip.fromFirestore(String docId, Map<String, dynamic> data) {
    final List<dynamic> rawPoints =
        data['routePoints'] as List<dynamic>? ?? <dynamic>[];
    return Trip(
      id: docId,
      deviceIdent: data['deviceIdent'] as String? ?? '',
      startTime: Parsers.fromUnknown(data['startTime']) ?? DateTime.now(),
      endTime: Parsers.fromUnknown(data['endTime']) ?? DateTime.now(),
      activeDurationMinutes: data['activeDurationMinutes'] as int?,
      routePoints: rawPoints
          .whereType<Map<String, dynamic>>()
          .map(RoutePoint.fromJson)
          .toList(growable: false),
    );
  }
}
