import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device_trip.dart';
import '../services/vercel_connector_service.dart';
import 'api_provider.dart';

final tripsProvider = StreamProvider<List<DeviceTrip>>((Ref ref) {
  final String deviceId = ref.watch(deviceIdentProvider).trim();
  if (deviceId.isEmpty) return Stream.value(const <DeviceTrip>[]);

  final VercelConnectorService service = ref.watch(vercelConnectorServiceProvider);

  // Poll the backend every 15 seconds and re-emit results. If an error
  // occurs, rethrow so the provider moves to the error state and the UI
  // can show the message.
  return (() async* {
    bool disposed = false;
    ref.onDispose(() => disposed = true);

    while (!disposed) {
      try {
        final List<Map<String, dynamic>> raw = await service.getTripsRaw(deviceId, limit: 50);
        final List<DeviceTrip> trips = raw
          .map((m) => DeviceTrip.fromFirestore(m['id'] as String? ?? '', m))
            .toList(growable: false);
        yield trips;
      } catch (e) {
        // rethrow to mark provider as error
        rethrow;
      }

      await Future<void>.delayed(const Duration(seconds: 15));
    }
  })();
});
