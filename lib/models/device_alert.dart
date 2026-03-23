import '../utils/parsers.dart';

enum DeviceAlertType { geofence, vibration, lowBattery, movement, unknown }

class DeviceAlert {
  const DeviceAlert({
    required this.type,
    required this.message,
    required this.timestamp,
    this.value,
    this.geofenceName,
    this.isEntering,
  });

  final DeviceAlertType type;
  final String message;
  final DateTime timestamp;
  final dynamic value;
  final String? geofenceName;
  final bool? isEntering;

  static DeviceAlert? fromBackendJson(Map<String, dynamic> json) {
    final String eventKind = (json['event_kind'] ?? '').toString();

    DeviceAlertType type = DeviceAlertType.unknown;
    bool? isEntering;

    if (eventKind == 'vibration_alert') {
      type = DeviceAlertType.vibration;
    } else if (eventKind == 'geofence_enter') {
      type = DeviceAlertType.geofence;
      isEntering = true;
    } else if (eventKind == 'geofence_exit') {
      type = DeviceAlertType.geofence;
      isEntering = false;
    } else if ((json['vibration_alarm'] == true)) {
      type = DeviceAlertType.vibration;
    } else if ((json['geofence_alarm'] == true)) {
      type = DeviceAlertType.geofence;
      isEntering = json['geofence_enter'] == true
          ? true
          : (json['geofence_exit'] == true ? false : null);
    }

    if (type == DeviceAlertType.unknown) {
      return null;
    }

    final DateTime timestamp =
        Parsers.fromUnknown(json['source_ts']) ??
        Parsers.fromUnknown(json['updated_at']) ??
        Parsers.fromUnknown(json['created_at']) ??
        Parsers.now();

    final String? geofenceName = json['geofence_name']?.toString();
    final String message =
        (json['message']?.toString().trim().isNotEmpty ?? false)
        ? json['message'].toString()
        : switch (type) {
            DeviceAlertType.vibration => '¡Vibración detectada!',
            DeviceAlertType.geofence =>
              isEntering == true
                  ? 'Entrada en geocerca detectada'
                  : 'Salida de geocerca detectada',
            DeviceAlertType.lowBattery => 'Batería baja detectada',
            DeviceAlertType.movement => 'Movimiento no autorizado detectado',
            DeviceAlertType.unknown => 'Alerta detectada',
          };

    return DeviceAlert(
      type: type,
      message: message,
      timestamp: timestamp,
      value: json['payload'] ?? json,
      geofenceName: geofenceName,
      isEntering: isEntering,
    );
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
