import 'package:latlong2/latlong.dart';

import '../utils/parsers.dart';

class DeviceTrip {
  const DeviceTrip({
    required this.id,
    required this.deviceId,
    required this.startedAt,
    required this.endedAt,
    required this.durationSec,
    required this.distanceM,
    required this.maxSpeedKph,
    required this.polylineEncoded,
    required this.pathPoints,
  });

  final String id;
  final String deviceId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSec;
  final double distanceM;
  final double maxSpeedKph;
  final String polylineEncoded;
  final List<LatLng> pathPoints;

  int get durationMinutes => (durationSec / 60).round();

  factory DeviceTrip.fromFirestore(String docId, Map<String, dynamic> data) {
    final DateTime started = Parsers.fromUnknown(data['startedAt']) ?? DateTime.now();
    final DateTime ended = Parsers.fromUnknown(data['endedAt']) ?? started;
    final String polyline = (data['polylineEncoded'] as String? ?? '').trim();

    return DeviceTrip(
      id: docId,
      deviceId: (data['deviceId'] as String? ?? '').trim(),
      startedAt: started,
      endedAt: ended,
      durationSec: _toInt(data['durationSec']) ?? ended.difference(started).inSeconds,
      distanceM: _toDouble(data['distanceM']) ?? 0,
      maxSpeedKph: _toDouble(data['maxSpeedKph']) ?? 0,
      polylineEncoded: polyline,
      pathPoints: polyline.isEmpty ? const <LatLng>[] : _decodePolyline(polyline),
    );
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _toDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      final _DecodeResult latResult = _decodeValue(encoded, index);
      index = latResult.nextIndex;
      lat += latResult.delta;

      final _DecodeResult lngResult = _decodeValue(encoded, index);
      index = lngResult.nextIndex;
      lng += lngResult.delta;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }

  static _DecodeResult _decodeValue(String encoded, int startIndex) {
    int result = 0;
    int shift = 0;
    int index = startIndex;

    while (index < encoded.length) {
      final int byte = encoded.codeUnitAt(index) - 63;
      index += 1;
      result |= (byte & 0x1f) << shift;
      shift += 5;
      if (byte < 0x20) break;
    }

    final int delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    return _DecodeResult(delta: delta, nextIndex: index);
  }
}

class _DecodeResult {
  const _DecodeResult({required this.delta, required this.nextIndex});

  final int delta;
  final int nextIndex;
}
