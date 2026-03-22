enum GeofenceType { circle, polygon }

class GeofencePoint {
  const GeofencePoint({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}

class Geofence {
  const Geofence({
    required this.id,
    required this.name,
    required this.type,
    this.latitude,
    this.longitude,
    this.radius,
    this.points = const <GeofencePoint>[],
  });

  final int id;
  final String name;
  final GeofenceType type;
  final double? latitude;
  final double? longitude;
  final double? radius; // in km
  final List<GeofencePoint> points;

  factory Geofence.fromJson(Map<String, dynamic> json) {
    final geometry = Map<String, dynamic>.from(json['geometry'] as Map);
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
      final List<dynamic> rawPoints = geometry['points'] as List<dynamic>? ?? const <dynamic>[];
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
      latitude: lat,
      longitude: lon,
      radius: radius,
      points: points,
    );
  }
}
