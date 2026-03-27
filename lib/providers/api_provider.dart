import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_position.dart';
import '../models/geofence.dart';
import '../services/flespi_api_service.dart';
import '../services/vercel_connector_service.dart';

class FlespiReadRequest {
  const FlespiReadRequest({
    required this.relativePath,
    this.queryParameters,
    this.body,
  });

  final String relativePath;
  final Map<String, String>? queryParameters;
  final Object? body;
}

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

typedef FlespiReadDevice =
    Future<Map<String, dynamic>> Function(FlespiReadRequest request);
typedef FlespiExecuteCommand =
    Future<Map<String, dynamic>> Function(FlespiCommandRequest request);

final deviceIdentProvider = Provider<String>((Ref ref) {
  return dotenv.env['DEVICE_IDENT'] ?? FlespiApiService.defaultDeviceIdent;
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

  throw const FlespiApiException(
    statusCode: 400,
    message: 'DEVICE_IDENT or DEVICE_ID is required in .env',
  );
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

final deviceGeofencesProvider = FutureProvider<List<Geofence>>((Ref ref) async {
  final FlespiApiService service = ref.watch(flespiApiServiceProvider);
  final String selector = ref.watch(deviceSelectorProvider);
  final String deviceId = ref.watch(deviceIdentProvider).trim();

  try {
    return await service.getDeviceGeofences(selector);
  } catch (_) {
    if (deviceId.isEmpty) {
      return const <Geofence>[];
    }

    try {
      return await ref
          .watch(vercelConnectorServiceProvider)
          .getManagedGeofences(deviceId);
    } catch (_) {
      return const <Geofence>[];
    }
  }
});

final deviceDetailsProvider = FutureProvider<Map<String, dynamic>>((
  Ref ref,
) async {
  final FlespiApiService service = ref.watch(flespiApiServiceProvider);
  final String selector = ref.watch(deviceSelectorProvider);

  try {
    final Map<String, dynamic> response = await service.getDevice(
      selector,
      fields: const <String>[
        'id',
        'name',
        'connected',
        'last_active',
        'protocol_name',
        'device_type_name',
      ],
    );

    final List<dynamic> result =
        response['result'] as List<dynamic>? ?? const <dynamic>[];
    if (result.isNotEmpty && result.first is Map) {
      return Map<String, dynamic>.from(result.first as Map);
    }
  } catch (_) {
    // fallback to vercel connector shape when flespi is unavailable
  }

  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) {
    throw Exception('DEVICE_ID is required in .env');
  }

  return ref
      .watch(vercelConnectorServiceProvider)
      .getSettingsDeviceInfo(deviceId);
});

final flespiApiServiceProvider = Provider<FlespiApiService>((Ref ref) {
  final FlespiApiService service = FlespiApiService(
    baseUrl: 'https://flespi.io',
    token: dotenv.env['FLESPI_TOKEN'] ?? '',
  );

  ref.onDispose(service.dispose);
  return service;
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
  return (dotenv.env['VERCEL_CONNECTOR_WRITE_BEARER'] ?? '').trim();
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

final managedGeofencesProvider = FutureProvider<List<Geofence>>((
  Ref ref,
) async {
  final String deviceId = ref.watch(deviceIdentProvider).trim();
  if (deviceId.isEmpty) {
    return const <Geofence>[];
  }

  final VercelConnectorService service = ref.watch(
    vercelConnectorServiceProvider,
  );
  return service.getManagedGeofences(deviceId);
});

final flespiRegisteredCatalogProvider = Provider<FlespiDeviceCatalog>((
  Ref ref,
) {
  final String ident = ref.watch(deviceIdentProvider);
  return FlespiApiService.registeredCatalog(ident: ident);
});

final flespiCapabilitiesProvider = FutureProvider<Map<String, dynamic>>((
  Ref ref,
) async {
  final FlespiApiService service = ref.watch(flespiApiServiceProvider);
  final String selector = ref.watch(deviceSelectorProvider);
  return service.getRegisteredCapabilities(selector);
});

final flespiReadDeviceProvider = Provider<FlespiReadDevice>((Ref ref) {
  final FlespiApiService service = ref.watch(flespiApiServiceProvider);
  final String selector = ref.watch(deviceSelectorProvider);

  return (FlespiReadRequest request) {
    return service.readDeviceEndpoint(
      selector: selector,
      relativePath: request.relativePath,
      queryParameters: request.queryParameters,
      body: request.body,
    );
  };
});

final flespiExecuteCommandProvider = Provider<FlespiExecuteCommand>((Ref ref) {
  final FlespiApiService service = ref.watch(flespiApiServiceProvider);
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
