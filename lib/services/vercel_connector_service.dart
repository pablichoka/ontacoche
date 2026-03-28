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

  Future<Map<String, dynamic>?> getDeviceStateMap(String deviceId) async {
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

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<DevicePosition?> getCurrentDeviceState(String deviceId) async {
    final Map<String, dynamic>? payload = await getDeviceStateMap(deviceId);
    if (payload == null) {
      return null;
    }

    final Map<String, dynamic>? state = payload['state'] is Map
        ? Map<String, dynamic>.from(payload['state'] as Map)
        : null;

    if (state == null) {
      return null;
    }

    // support new compact state shape where position is nested
    final Map<String, dynamic>? positionMap = (state['position'] is Map)
        ? Map<String, dynamic>.from(state['position'] as Map)
        : null;

    final double? latitude = _toDouble(
      positionMap?['latitude'] ?? state['latitude'],
    );
    final double? longitude = _toDouble(
      positionMap?['longitude'] ?? state['longitude'],
    );
    if (latitude == null || longitude == null) {
      return null;
    }

    final double? altitude = _toDouble(
      positionMap?['altitude'] ?? state['altitude'],
    );
    final double? speed = _toDouble(positionMap?['speed'] ?? state['speed']);
    final double? batteryLevel = _toDouble(
      (state['battery'] is Map)
          ? Map<String, dynamic>.from(state['battery'] as Map)['level'] ??
                state['battery_level']
          : state['battery_level'],
    );

    return DevicePosition(
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      speed: speed,
      batteryLevel: batteryLevel,
      timestamp: Parsers.fromUnknown(state['source_ts']),
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

  Future<int> deleteDeviceAlertsForDevice(String deviceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/device-alerts?device_id=$deviceId');
    final Map<String, String> headers = _writeHeaders();

    final http.Response response = await _client.delete(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload = jsonDecode(response.body) as Map<String, dynamic>;
    final Object? deleted = payload['deleted'];
    if (deleted is num) return deleted.toInt();
    return int.tryParse(deleted?.toString() ?? '') ?? 0;
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
    final Map<String, dynamic>? payload = await getDeviceStateMap(deviceId);
    final Map<String, dynamic>? state = payload?['state'] is Map
        ? Map<String, dynamic>.from(payload!['state'] as Map)
        : null;

    String name = 'Tracker $deviceId';
    DateTime? ts;

    if (state != null) {
      final Map<String, dynamic>? deviceData = (state['device'] is Map)
          ? Map<String, dynamic>.from(state['device'] as Map)
          : null;
      if (deviceData != null && deviceData['name'] != null) {
        name = deviceData['name'].toString();
      }
      ts = Parsers.fromUnknown(state['source_ts']);
    }

    final bool connected =
        ts != null &&
        Parsers.now().difference(ts) <= const Duration(minutes: 5);

    return <String, dynamic>{
      'id': deviceId,
      'name': name,
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

  Future<List<Map<String, dynamic>>> getTripsRaw(String deviceId, {int limit = 20}) async {
    final Uri uri = Uri.parse('$baseUrl/api/trips?device_id=$deviceId&limit=$limit');
    final Map<String, String> headers = _readHeaders();

    final http.Response response = await _client.get(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload = jsonDecode(response.body) as Map<String, dynamic>;
    final List<dynamic> tripsRaw = payload['trips'] as List<dynamic>? ?? const <dynamic>[];
    return tripsRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList(growable: false);
  }

  Future<int> deleteTripsForDevice(String deviceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/trips?device_id=$deviceId');
    final Map<String, String> headers = _writeHeaders();

    final http.Response response = await _client.delete(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final Map<String, dynamic> payload = jsonDecode(response.body) as Map<String, dynamic>;
    final Object? deleted = payload['deleted'];
    if (deleted is num) return deleted.toInt();
    return int.tryParse(deleted?.toString() ?? '') ?? 0;
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

  Future<Map<String, dynamic>> sendCommand(
    String selector, {
    required String commandName,
    required Map<String, dynamic> properties,
    bool queue = false,
    int? timeout,
    int? ttl,
    int? priority,
    int? maxAttempts,
    String? condition,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/command');
    final Map<String, dynamic> body = <String, dynamic>{
      'selector': selector,
      'name': commandName,
      'properties': properties,
      'queue': queue,
      if (timeout != null) 'timeout': timeout,
      if (ttl != null) 'ttl': ttl,
      if (priority != null) 'priority': priority,
      if (maxAttempts != null) 'maxAttempts': maxAttempts,
      if (condition != null) 'condition': condition,
    };

    final http.Response response = await _client.post(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(body),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final dynamic decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{'result': decoded};
  }

  Future<Map<String, dynamic>> updateDeviceName(
    String selector,
    String name,
  ) async {
    final Uri uri = Uri.parse('$baseUrl/api/device');
    final Map<String, dynamic> body = <String, dynamic>{
      'selector': selector,
      'name': name,
    };

    final http.Response response = await _client.put(
      uri,
      headers: _writeHeaders(),
      body: jsonEncode(body),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VercelConnectorException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }

    final dynamic decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{'result': decoded};
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
