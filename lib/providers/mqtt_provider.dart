import 'dart:async';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ontacoche/services/telemetry_database_service.dart';

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/telemetry_record.dart';
import '../services/mqtt_service.dart';
import 'telemetry_provider.dart';

typedef MqttTopicSubscriber = Future<void> Function(String topic);

final mqttServiceProvider = Provider<MqttService>((Ref ref) {
  final String broker = dotenv.env['MQTT_BROKER'] ?? 'mqtt.flespi.io';
  final int port = int.tryParse(dotenv.env['MQTT_PORT'] ?? '443') ?? 443;
  final String token = dotenv.env['FLESPI_TOKEN'] ?? '';
  final String deviceId = dotenv.env['DEVICE_ID'] ?? '';
  final String? geofenceCalcId = dotenv.env['FLESPI_GEOFENCE_CALC_ID'];
  final Future<void> Function(DevicePosition) persistTelemetry =
      ref.watch(persistTelemetryUseCaseProvider);

  final MqttService service = MqttService(
    broker: broker,
    port: port,
    token: token,
    deviceId: deviceId,
    geofenceCalcId: geofenceCalcId,
    onPositionReceived: persistTelemetry,
  );

  final Future<void> Function(DeviceAlert) persistAlert = ref.watch(persistAlertUseCaseProvider);
  final StreamSubscription<DeviceAlert> alertSubscription = service.alerts.listen((DeviceAlert alert) {
    unawaited(persistAlert(alert));
  });

  // Forward unseen count from DB to the MqttService so MQTT layer can expose it
  final TelemetryDatabaseService dbService = ref.watch(telemetryDatabaseServiceProvider);
  final StreamSubscription<int> unseenSubscription = dbService.watchUnseenCount().listen((int count) {
    service.publishUnseenCount(count);
  });

  ref.onDispose(() async {
    await alertSubscription.cancel();
    await unseenSubscription.cancel();
    await service.dispose();
  });

  return service;
});

final mqttConnectionProvider = FutureProvider<void>((Ref ref) async {
  final MqttService service = ref.watch(mqttServiceProvider);

  if ((dotenv.env['FLESPI_TOKEN'] ?? '').isEmpty) {
    throw const MqttServiceException('FLESPI_TOKEN is missing in .env');
  }

  if ((dotenv.env['DEVICE_ID'] ?? '').isEmpty) {
    throw const MqttServiceException('DEVICE_ID is missing in .env');
  }

  await service.connect();
});

final positionStreamProvider = StreamProvider<DevicePosition>((Ref ref) async* {
  final Stream<List<TelemetryRecord>> recordsStream = ref.watch(telemetryHistoryProvider.stream);
  await for (final List<TelemetryRecord> records in recordsStream) {
    if (records.isEmpty) {
      continue;
    }

    final TelemetryRecord record = records.first;
    yield DevicePosition(
      latitude: record.latitude,
      longitude: record.longitude,
      altitude: record.altitude,
      speed: record.speed,
      timestamp: record.recordedAt,
      batteryLevel: record.batteryLevel,
    );
  }
});

final alertStreamProvider = StreamProvider<DeviceAlert>((Ref ref) async* {
  final Stream<List<DeviceAlert>> alertsStream = ref.watch(alertsHistoryProvider.stream);
  await for (final List<DeviceAlert> alerts in alertsStream) {
    if (alerts.isEmpty) {
      continue;
    }

    yield alerts.first;
  }
});

final mqttRegisteredTopicsProvider = Provider<List<MqttTopicDefinition>>((Ref ref) {
  final MqttService service = ref.watch(mqttServiceProvider);
  return service.registeredTopics;
});

final mqttSubscribeTopicProvider = Provider<MqttTopicSubscriber>((Ref ref) {
  final MqttService service = ref.watch(mqttServiceProvider);
  return (String topic) => service.subscribeTopic(topic);
});

final mqttRawMessagesProvider = StreamProvider<MqttEnvelope>((Ref ref) async* {
  await ref.watch(mqttConnectionProvider.future);
  final MqttService service = ref.watch(mqttServiceProvider);
  yield* service.messages;
});

final mqttTopicStreamProvider = StreamProvider.family<MqttEnvelope, String>((Ref ref, String topic) async* {
  await ref.watch(mqttConnectionProvider.future);
  final MqttService service = ref.watch(mqttServiceProvider);
  await service.subscribeTopic(topic);
  yield* service.topicMessages(topic);
});