import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../utils/parsers.dart';

class VercelConnectorService {
  VercelConnectorService({
    required this.baseUrl,
    required this.readBearer,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String readBearer;
  final http.Client _client;

  Future<DevicePosition?> getCurrentDeviceState(String deviceId) async {
    final Uri uri = Uri.parse('$baseUrl/api/device-state?device_id=$deviceId');
    final Map<String, String> headers = <String, String>{};
    if (readBearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $readBearer';
    }

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
    final Map<String, String> headers = <String, String>{};
    if (readBearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $readBearer';
    }

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
