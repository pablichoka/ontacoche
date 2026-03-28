import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_position.dart';
import '../models/geofence.dart';
import '../services/vercel_connector_service.dart';

class FlespiCommandRequest {
  const FlespiCommandRequest({
    required this.name,
    required this.properties,
    this.queue = false,
    this.timeout,
    this.ttl,
    this.priority,
    this.maxAttempts,
    this.condition,
  });

  final String name;
  final Map<String, dynamic> properties;
  final bool queue;
  final int? timeout;
  final int? ttl;
  final int? priority;
  final int? maxAttempts;
  final String? condition;
}

typedef FlespiExecuteCommand =
    Future<Map<String, dynamic>> Function(FlespiCommandRequest request);

final deviceIdentProvider = Provider<String>((Ref ref) {
  return dotenv.env['DEVICE_IDENT'] ?? '009590067804';
});

final deviceSelectorProvider = Provider<String>((Ref ref) {
  final String ident = ref.watch(deviceIdentProvider).trim();
  if (ident.isNotEmpty) {
    return 'configuration.ident=$ident';
  }

  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isNotEmpty) {
    return deviceId;
  }

  throw Exception('DEVICE_IDENT or DEVICE_ID is required in .env');
});

final initialDevicePositionProvider = FutureProvider<DevicePosition?>((
  Ref ref,
) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) {
    return null;
  }

  return ref
      .watch(vercelConnectorServiceProvider)
      .getCurrentDeviceState(deviceId);
});

final deviceGeofencesProvider = StreamProvider<List<Geofence>>((
  Ref ref,
) async* {
  final String deviceId = ref.watch(deviceIdentProvider).trim();
  if (deviceId.isEmpty) {
    yield const <Geofence>[];
    return;
  }

  final service = ref.watch(vercelConnectorServiceProvider);
  bool disposed = false;
  ref.onDispose(() => disposed = true);

  while (!disposed) {
    try {
      final current = await service.getManagedGeofences(deviceId);
      if (!disposed) yield current;
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});

final deviceDetailsProvider = FutureProvider<Map<String, dynamic>>((
  Ref ref,
) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) {
    throw Exception('DEVICE_ID is required in .env');
  }

  return ref
      .watch(vercelConnectorServiceProvider)
      .getSettingsDeviceInfo(deviceId);
});

final vercelConnectorBaseUrlProvider = Provider<String>((Ref ref) {
  final String fromEnv = (dotenv.env['VERCEL_CONNECTOR_URL'] ?? '').trim();
  if (fromEnv.isNotEmpty) {
    return fromEnv;
  }

  return 'https://ontacoche.vercel.app';
});

final vercelConnectorReadBearerProvider = Provider<String>((Ref ref) {
  return (dotenv.env['VERCEL_CONNECTOR_READ_BEARER'] ?? '').trim();
});

final vercelConnectorWriteBearerProvider = Provider<String>((Ref ref) {
  final String writeBearer = (dotenv.env['VERCEL_CONNECTOR_WRITE_BEARER'] ?? '')
      .trim();
  if (writeBearer.isNotEmpty) {
    return writeBearer;
  }

  return ref.watch(vercelConnectorReadBearerProvider);
});

final vercelConnectorServiceProvider = Provider<VercelConnectorService>((
  Ref ref,
) {
  final VercelConnectorService service = VercelConnectorService(
    baseUrl: ref.watch(vercelConnectorBaseUrlProvider),
    readBearer: ref.watch(vercelConnectorReadBearerProvider),
    writeBearer: ref.watch(vercelConnectorWriteBearerProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

final deviceRawStateProvider = FutureProvider<Map<String, dynamic>?>((
  Ref ref,
) async {
  final String deviceId = ref.watch(deviceIdentProvider).trim();
  if (deviceId.isEmpty) return null;
  final VercelConnectorService service = ref.watch(
    vercelConnectorServiceProvider,
  );
  return service.getDeviceStateMap(deviceId);
});

final managedGeofencesProvider = Provider<AsyncValue<List<Geofence>>>((
  Ref ref,
) {
  return ref.watch(deviceGeofencesProvider);
});

final flespiExecuteCommandProvider = Provider<FlespiExecuteCommand>((Ref ref) {
  final VercelConnectorService service = ref.watch(
    vercelConnectorServiceProvider,
  );
  final String selector = ref.watch(deviceSelectorProvider);

  return (FlespiCommandRequest request) {
    return service.sendCommand(
      selector,
      commandName: request.name,
      properties: request.properties,
      queue: request.queue,
      timeout: request.timeout,
      ttl: request.ttl,
      priority: request.priority,
      maxAttempts: request.maxAttempts,
      condition: request.condition,
    );
  };
});
