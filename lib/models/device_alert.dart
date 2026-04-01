import '../utils/parsers.dart';

enum DeviceAlertType { geofence, vibration, lowBattery, movement, unknown }

class DeviceAlert {
  const DeviceAlert({
    this.id,
    required this.type,
    required this.message,
    required this.timestamp,
    this.value,
    this.geofenceName,
    this.isEntering,
    this.checked = false,
    this.dedupeKey,
  });

  final String? id;
  final DeviceAlertType type;
  final String message;
  final DateTime timestamp;
  final dynamic value;
  final String? geofenceName;
  final bool? isEntering;
  final bool checked;
  final String? dedupeKey;

  static DeviceAlert? fromBackendJson(Map<String, dynamic> json) {
    final Map<String, dynamic> payload = json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : const <String, dynamic>{};

    final String eventKind =
        (json['event_kind'] ??
                json['event_type'] ??
                payload['event_kind'] ??
                payload['event_type'] ??
                '')
            .toString()
            .toLowerCase();
    final String messageText =
        (json['message'] ??
                json['body'] ??
                payload['message'] ??
                payload['body'] ??
                '')
            .toString()
            .toLowerCase();
    final String titleText = (json['title'] ?? payload['title'] ?? '')
        .toString()
        .toLowerCase();
    final dynamic geofenceRaw =
        json['geofence_name'] ??
        json['geofence'] ??
        payload['geofence_name'] ??
        payload['geofence'];
    final bool vibrationAlarm =
        json['vibration_alarm'] == true ||
        payload['vibration_alarm'] == true ||
        payload['vibration.alarm'] == true;
    final bool geofenceAlarm =
        json['geofence_alarm'] == true || payload['geofence_alarm'] == true;
    final bool geofenceEnterFlag =
        json['geofence_enter'] == true || payload['geofence_enter'] == true;
    final bool geofenceExitFlag =
        json['geofence_exit'] == true || payload['geofence_exit'] == true;

    DeviceAlertType type = DeviceAlertType.unknown;
    bool? isEntering;

    if (eventKind == 'vibration_alert' ||
        eventKind == 'vibration' ||
        eventKind.contains('vibration')) {
      type = DeviceAlertType.vibration;
    } else if (eventKind == 'geofence_enter' || eventKind == 'enter') {
      type = DeviceAlertType.geofence;
      isEntering = true;
    } else if (eventKind == 'geofence_exit' || eventKind == 'exit') {
      type = DeviceAlertType.geofence;
      isEntering = false;
    } else if (eventKind == 'geofence_config_created' ||
        eventKind == 'geofence_config_deleted') {
      type = DeviceAlertType.geofence;
      isEntering = null;
    } else if (vibrationAlarm) {
      type = DeviceAlertType.vibration;
    } else if (geofenceAlarm) {
      if (geofenceEnterFlag == geofenceExitFlag) {
        return null;
      }

      type = DeviceAlertType.geofence;
      isEntering = geofenceEnterFlag;
    } else if (json['alarm'] == true) {
      type = DeviceAlertType.vibration;
    } else if (messageText.contains('vibr') || titleText.contains('vibr')) {
      type = DeviceAlertType.vibration;
    }

    if (type == DeviceAlertType.unknown) {
      final bool hasMeaningfulText =
          messageText.trim().isNotEmpty ||
          titleText.trim().isNotEmpty ||
          eventKind.trim().isNotEmpty;
      if (!hasMeaningfulText) {
        return null;
      }
    }

    final DateTime timestamp = _timestampFromBackendJson(json);
    final bool checked =
        _parseChecked(json['checked'] ?? json['seen']) ?? false;

    final String? geofenceName = geofenceRaw?.toString();
    final String message =
        ((json['message'] ?? json['body'])?.toString().trim().isNotEmpty ??
            false)
        ? (json['message'] ?? json['body']).toString()
        : switch (type) {
            DeviceAlertType.vibration => '¡Vibración detectada!',
            DeviceAlertType.geofence =>
              isEntering == null
                  ? 'Evento de geocerca'
                  : (isEntering
                        ? 'Entrada en geocerca detectada'
                        : 'Salida de geocerca detectada'),
            DeviceAlertType.lowBattery => 'Batería baja detectada',
            DeviceAlertType.movement => 'Movimiento no autorizado detectado',
            DeviceAlertType.unknown => 'Alerta detectada',
          };

    return DeviceAlert(
      id: json['id']?.toString(),
      type: type,
      message: message,
      timestamp: timestamp,
      value: json['payload'] ?? json,
      geofenceName: geofenceName,
      isEntering: isEntering,
      checked: checked,
      dedupeKey: json['dedupe_key']?.toString(),
    );
  }

  static bool? _parseChecked(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is bool) {
      return raw;
    }
    if (raw is num) {
      return raw != 0;
    }
    final String value = raw.toString().trim().toLowerCase();
    if (value == 'true' || value == '1' || value == 'yes') {
      return true;
    }
    if (value == 'false' || value == '0' || value == 'no') {
      return false;
    }
    return null;
  }

  static DateTime _timestampFromBackendJson(Map<String, dynamic> json) {
    final DateTime? sourceTs = Parsers.fromUnknown(json['source_ts']);
    if (sourceTs != null) {
      return sourceTs;
    }

    final DateTime? createdAt = Parsers.fromUnknown(json['created_at']);
    if (createdAt != null) {
      return createdAt;
    }

    // fallback when backend misses temporal fields
    return Parsers.now();
  }

  static List<DeviceAlert> fromDeviceMessage(Map<String, dynamic> json) {
    final List<DeviceAlert> alerts = <DeviceAlert>[];
    final DateTime ts = _timestampFromMessage(json);

    if (json['vibration.alarm'] == true) {
      alerts.add(
        DeviceAlert(
          type: DeviceAlertType.vibration,
          message: '¡Vibración detectada!',
          timestamp: ts,
          value: true,
          checked: false,
        ),
      );
    }

    if (json['battery.low.alarm'] == true) {
      alerts.add(
        DeviceAlert(
          type: DeviceAlertType.lowBattery,
          message: 'Batería baja detectada',
          timestamp: ts,
          value: true,
          checked: false,
        ),
      );
    }

    if (json['illegal.movement.alarm'] == true) {
      alerts.add(
        DeviceAlert(
          type: DeviceAlertType.movement,
          message: 'Movimiento no autorizado detectado',
          timestamp: ts,
          value: true,
          checked: false,
        ),
      );
    }

    return alerts;
  }

  static DeviceAlert? fromCalculatorInterval(Map<String, dynamic> json) {
    final String? type = json['type']?.toString();
    if (type != 'enter' && type != 'exit') {
      return null;
    }

    final bool isEntering = type == 'enter';
    final String geofenceName = json['geofence']?.toString() ?? '';
    final DateTime ts = _timestampFromInterval(json);

    return DeviceAlert(
      type: DeviceAlertType.geofence,
      message: isEntering
          ? geofenceName.isEmpty
                ? 'Entrada en geocerca detectada'
                : 'Entrada en geocerca: $geofenceName'
          : geofenceName.isEmpty
          ? 'Salida de geocerca detectada'
          : 'Salida de geocerca: $geofenceName',
      timestamp: ts,
      value: type,
      geofenceName: geofenceName.isEmpty ? null : geofenceName,
      isEntering: isEntering,
      checked: false,
    );
  }

  static DateTime _timestampFromMessage(Map<String, dynamic> json) {
    final dynamic serverTimestamp = json['server.timestamp'];
    if (serverTimestamp is num) {
      return Parsers.fromUnixSeconds(serverTimestamp);
    }

    final dynamic timestamp = json['timestamp'];
    if (timestamp is num) {
      return Parsers.fromUnixSeconds(timestamp);
    }

    return Parsers.now();
  }

  static DateTime _timestampFromInterval(Map<String, dynamic> json) {
    // try server.timestamp first if present (unlikely in interval, but good for consistency)
    final dynamic serverTs = json['server.timestamp'];
    if (serverTs is num) {
      return Parsers.fromUnixSeconds(serverTs);
    }

    final dynamic end = json['end'];
    if (end is num) {
      return Parsers.fromUnixSeconds(end);
    }

    final dynamic begin = json['begin'];
    if (begin is num) {
      return Parsers.fromUnixSeconds(begin);
    }

    return Parsers.now();
  }
}
