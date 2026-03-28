import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../services/trip_service.dart';
import 'api_provider.dart';

final tripServiceProvider = Provider<TripService>((Ref ref) {
  return TripService();
});

final tripsProvider = StreamProvider<List<Trip>>((Ref ref) {
  final String deviceId = ref.watch(deviceIdentProvider).trim();
  if (deviceId.isEmpty) return Stream.value(const <Trip>[]);
  final TripService service = ref.watch(tripServiceProvider);
  return service.watchTrips(deviceId);
});
