import 'dart:ui';

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/device_alert.dart';
import '../models/telemetry_record.dart';
import '../services/mqtt_service.dart';
import '../services/telemetry_database_service.dart';

const int _notificationId = 3201;
const int _alertNotificationStartId = 4000;
const String _channelId = 'ontacoche_tracking';
const String _channelName = 'OntaCoche Tracking';
const String _alertsChannelId = 'ontacoche_alerts';
const String _alertsChannelName = 'Alertas de OntaCoche';

Future<void> initializeBackgroundTrackingService() async {
  final FlutterBackgroundService service = FlutterBackgroundService();

  if (Platform.isAndroid) {
    final FlutterLocalNotificationsPlugin flnPlugin =
        FlutterLocalNotificationsPlugin();
    await flnPlugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin = 
        flnPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Canal para seguimiento MQTT en segundo plano',
        importance: Importance.min,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _alertsChannelId,
        _alertsChannelName,
        description: 'Notificaciones de entrada/salida y estado del coche',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: _channelId,
      initialNotificationTitle: 'OntaCoche',
      initialNotificationContent: 'Conectando...',
      foregroundServiceNotificationId: _notificationId,
      foregroundServiceTypes: <AndroidForegroundType>[
        AndroidForegroundType.dataSync,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _onServiceStart,
      onBackground: _onIosBackground,
    ),
  );
}

Future<void> startBackgroundTrackingServiceIfAllowed() async {
  final FlutterBackgroundService service = FlutterBackgroundService();
  if (await service.isRunning()) {
    return;
  }

  if (Platform.isAndroid) {
    if (!await Permission.notification.isGranted) {
      final PermissionStatus status = await Permission.notification.request();
      if (!status.isGranted) {
        return;
      }
    }
  }

  await service.startService();
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
Future<void> _onServiceStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // ignore repeated dotenv loads in secondary isolate
  }

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'OntaCoche',
      content: 'Seguimiento MQTT activo',
    );
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  final String token = (dotenv.env['FLESPI_TOKEN'] ?? '').trim();
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (token.isEmpty || deviceId.isEmpty) {
    return;
  }

  final TelemetryDatabaseService database = TelemetryDatabaseService();
  final FlutterLocalNotificationsPlugin flnPlugin = FlutterLocalNotificationsPlugin();
  int alertIdCounter = _alertNotificationStartId;

  final MqttService mqttService = MqttService(
    broker: dotenv.env['MQTT_BROKER'] ?? 'mqtt.flespi.io',
    port: int.tryParse(dotenv.env['MQTT_PORT'] ?? '443') ?? 443,
    token: token,
    deviceId: deviceId,
    geofenceCalcId: dotenv.env['FLESPI_GEOFENCE_CALC_ID'],
    onPositionReceived: (position) async {
      await database.insertRecord(
        TelemetryRecord.fromDevicePosition(
          deviceId: deviceId,
          position: position,
        ),
      );
    },
    onAlertReceived: (alert) async {
      final bool inserted = await database.insertAlert(alert, deviceId: deviceId);
      
      // only notify if it's a new alert (not a duplicate)
      if (inserted) {
        await flnPlugin.show(
          alertIdCounter++,
          'OntaCoche: ${alert.type == DeviceAlertType.geofence ? (alert.isEntering ?? true ? "Entrada" : "Salida") : "Aviso"}',
          alert.message,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _alertsChannelId,
              _alertsChannelName,
              importance: Importance.max,
              priority: Priority.high,
              showWhen: true,
            ),
          ),
        );
        
        // reset counter if too high to avoid overflow over time
        if (alertIdCounter > 5000) alertIdCounter = _alertNotificationStartId;
      }
    },
  );

  service.on('stopService').listen((_) async {
    await mqttService.dispose();
    await database.dispose();
    await service.stopSelf();
  });

  try {
    await mqttService.connect();
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'OntaCoche',
        content: 'Información en vivo activa',
      );
    }
  } catch (_) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'OntaCoche',
        content: 'Esperando reconexión MQTT',
      );
    }
  }
}