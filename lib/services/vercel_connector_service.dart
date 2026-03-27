import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/geofence.dart';
import '../utils/parsers.dart';

class VercelConnectorService {
  VercelConnectorService({
    required this.baseUrl,
    required this.readBearer,
    required this.writeBearer,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String readBearer;
  final String writeBearer;
  final http.Client _client;

  Map<String, String> _readHeaders() {
    final Map<String, String> headers = <String, String>{};
    if (readBearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $readBearer';
    }
    return headers;
  }

  Map<String, String> _writeHeaders() {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (writeBearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $writeBearer';
    } else if (readBearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $readBearer';
    }
    return headers;
  }

  Future<DevicePosition?> getCurrentDeviceState(String deviceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/device-state?device_id=$deviceId');
    final Map<String, String> headers = _readHeaders();

    final http.Response response = await _client.get(uri, headers: headers);
    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Map<String, dynamic>? state = payload['state'] is Map
        ? Map<String, dynamic>.from(payload['state'] as Map)
        : null;

    if (state == null) {
      return null;
    }

    final double? latitude = _toDouble(state['latitude']);
    final double? longitude = _toDouble(state['longitude']);
    if (latitude == null || longitude == null) {
      return null;
    }

    return DevicePosition(
      latitude: latitude,
      longitude: longitude,
      altitude: _toDouble(state['altitude']),
      speed: _toDouble(state['speed']),
      batteryLevel: _toDouble(state['battery_level']),
      timestamp:
          Parsers.fromUnknown(state['source_ts']) ??
          Parsers.fromUnknown(state['updated_at']),
    );
  }

  Future<List<DeviceAlert>> getDeviceAlerts(
    String deviceId, {
    int limit = 50,
  }) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/device-alerts?device_id=$deviceId&limit=$limit',
    );
    final Map<String, String> headers = _readHeaders();

    final http.Response response = await _client.get(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final List<dynamic> alertsRaw =
        payload['alerts'] as List<dynamic>? ?? const <dynamic>[];
    return alertsRaw
        .whereType<Map>()
        .map(
          (Map item) =>
              DeviceAlert.fromBackendJson(Map<String, dynamic>.from(item)),
        )
        .whereType<DeviceAlert>()
        .toList(growable: false);
  }

  Future<int> markAlertsChecked(
    String deviceId, {
    List<String>? alertIds,
    int limit = 200,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/device-alerts');
    final Map<String, String> headers = _readHeaders()
      ..putIfAbsent('Content-Type', () => 'application/json');

    final Map<String, dynamic> body = <String, dynamic>{
      'device_id': deviceId,
      'limit': limit,
    };

    if (alertIds != null && alertIds.isNotEmpty) {
      body['alert_ids'] = alertIds;
    }

    final http.Response response = await _client.post(
      uri,
      headers: headers,
      body: jsonEncode(body),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Object? marked = payload['marked'];
    if (marked is num) {
      return marked.toInt();
    }

    return int.tryParse(marked?.toString() ?? '') ?? 0;
  }

  Future<Map<String, dynamic>> getSettingsDeviceInfo(String deviceId) async {
    final DevicePosition? position = await getCurrentDeviceState(deviceId);
    final DateTime? ts = position?.timestamp;
    final bool connected =
        ts != null &&
        Parsers.now().difference(ts) <= const Duration(minutes: 5);

    return <String, dynamic>{
      'id': deviceId,
      'name': 'Tracker $deviceId',
      'protocol_name': 'flespi-stream',
      'device_type_name': 'tracker',
      'connected': connected,
      'last_active': ts?.toIso8601String(),
    };
  }

  Future<List<Geofence>> getManagedGeofences(String deviceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences?device_id=$deviceId');
    final http.Response response = await _client.get(
      uri,
      headers: _writeHeaders(),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final List<dynamic> rows =
        payload['geofences'] as List<dynamic>? ?? const <dynamic>[];

    return rows
        .whereType<Map>()
        .map((Map row) => Geofence.fromJson(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<Geofence> createCircleGeofence({
    required String deviceId,
    required String name,
    required int priority,
    required double latitude,
    required double longitude,
    required double radiusKm,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences');
    final http.Response response = await _client.post(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(<String, dynamic>{
        'device_id': deviceId,
        'name': name,
        'priority': priority,
        'geometry': <String, dynamic>{
          'type': 'circle',
          'center': <String, dynamic>{'lat': latitude, 'lon': longitude},
          'radius': radiusKm,
        },
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Object? geofenceRaw = payload['geofence'];
    if (geofenceRaw is! Map) {
      throw const VercelConnectorException(
        statusCode: 500,
        message: 'invalid geofence response',
      );
    }

    return Geofence.fromJson(Map<String, dynamic>.from(geofenceRaw));
  }

  Future<Geofence> createPolygonGeofence({
    required String deviceId,
    required String name,
    required int priority,
    required List<Map<String, double>> path,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences');
    final http.Response response = await _client.post(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(<String, dynamic>{
        'device_id': deviceId,
        'name': name,
        'priority': priority,
        'geometry': <String, dynamic>{'type': 'polygon', 'path': path},
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Object? geofenceRaw = payload['geofence'];
    if (geofenceRaw is! Map) {
      throw const VercelConnectorException(
        statusCode: 500,
        message: 'invalid geofence response',
      );
    }

    return Geofence.fromJson(Map<String, dynamic>.from(geofenceRaw));
  }

  Future<Geofence> updateCircleGeofence({
    required int geofenceId,
    required String name,
    required int priority,
    required double latitude,
    required double longitude,
    required double radiusKm,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences/$geofenceId');
    final http.Response response = await _client.patch(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(<String, dynamic>{
        'name': name,
        'priority': priority,
        'geometry': <String, dynamic>{
          'type': 'circle',
          'center': <String, dynamic>{'lat': latitude, 'lon': longitude},
          'radius': radiusKm,
        },
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Object? geofenceRaw = payload['geofence'];
    if (geofenceRaw is! Map) {
      throw const VercelConnectorException(
        statusCode: 500,
        message: 'invalid geofence response',
      );
    }

    return Geofence.fromJson(Map<String, dynamic>.from(geofenceRaw));
  }

  Future<Geofence> updatePolygonGeofence({
    required int geofenceId,
    required String name,
    required int priority,
    required List<Map<String, double>> path,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences/$geofenceId');
    final http.Response response = await _client.patch(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(<String, dynamic>{
        'name': name,
        'priority': priority,
        'geometry': <String, dynamic>{'type': 'polygon', 'path': path},
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Object? geofenceRaw = payload['geofence'];
    if (geofenceRaw is! Map) {
      throw const VercelConnectorException(
        statusCode: 500,
        message: 'invalid geofence response',
      );
    }

    return Geofence.fromJson(Map<String, dynamic>.from(geofenceRaw));
  }

  Future<void> deleteGeofence(int geofenceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/geofences/$geofenceId');
    final http.Response response = await _client.delete(
      uri,
      headers: _writeHeaders(),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }
  }

  Future<void> assignGeofenceToDevice({
    required int geofenceId,
    required String deviceId,
  }) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/geofences/$geofenceId/assign-device',
    );
    final http.Response response = await _client.post(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(<String, dynamic>{'device_id': deviceId}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }
  }

  double? _toDouble(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  void dispose() {
    _client.close();
  }
}

class VercelConnectorException implements Exception {
  const VercelConnectorException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => 'VercelConnectorException($statusCode): $message';
}
