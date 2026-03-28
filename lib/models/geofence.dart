enum GeofenceType { circle, polygon }

class GeofencePoint {
  const GeofencePoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class Geofence {
  const Geofence({
    required this.id,
    required this.name,
    required this.type,
    required this.priority,
    this.latitude,
    this.longitude,
    this.radius,
    this.points = const <GeofencePoint>[],
  });

  final int id;
  final String name;
  final GeofenceType type;
  final int priority;
  final double? latitude;
  final double? longitude;
  final double? radius; // in m
  final List<GeofencePoint> points;

  factory Geofence.fromJson(Map<String, dynamic> json) {
    final geometryRaw = json['geometry'];
    final geometry = geometryRaw is Map
        ? Map<String, dynamic>.from(geometryRaw)
        : const <String, dynamic>{};
    final typeStr = geometry['type'] as String? ?? 'circle';

    GeofenceType type = GeofenceType.circle;
    double? lat;
    double? lon;
    double? radius;
    List<GeofencePoint> points = const <GeofencePoint>[];

    if (typeStr == 'circle') {
      type = GeofenceType.circle;
      final center = Map<String, dynamic>.from(geometry['center'] as Map);
      lat = center['lat']?.toDouble();
      lon = center['lon']?.toDouble();
      radius = geometry['radius']?.toDouble();
    } else if (typeStr == 'polygon') {
      type = GeofenceType.polygon;
      final List<dynamic> rawPoints =
          geometry['path'] as List<dynamic>? ??
          geometry['points'] as List<dynamic>? ??
          const <dynamic>[];
      points = rawPoints
          .whereType<Map>()
          .map(
            (Map point) => GeofencePoint(
              latitude: (point['lat'] as num).toDouble(),
              longitude: (point['lon'] as num).toDouble(),
            ),
          )
          .toList(growable: false);
    }

    return Geofence(
      id: json['id'],
      name: json['name'],
      type: type,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      latitude: lat,
      longitude: lon,
      radius: radius,
      points: points,
    );
  }
}
