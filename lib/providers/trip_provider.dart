import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../services/trip_service.dart';

final tripServiceProvider = Provider<TripService>((Ref ref) {
  return TripService();
});

final tripsProvider = FutureProvider<List<Trip>>((Ref ref) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();
  if (deviceId.isEmpty) return const <Trip>[];
  final TripService service = ref.watch(tripServiceProvider);
  return service.fetchTrips(deviceId);
});
