import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/device_trip.dart';

class TripService {
  TripService({String? collectionName})
    : _collectionName = collectionName ?? 'device_trips';

  final String _collectionName;

  Future<List<DeviceTrip>> fetchTrips(String deviceId, {int limit = 20}) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection(_collectionName)
              .where('deviceId', isEqualTo: deviceId)
              .orderBy('startedAt', descending: true)
              .limit(limit)
              .get();

      final List<DeviceTrip> trips = snapshot.docs
          .map((doc) => DeviceTrip.fromFirestore(doc.id, doc.data()))
          .toList(growable: false);
      return trips;
    } catch (e) {
      // Log the error so it's visible during debugging instead of silently
      // returning an empty list.
      // ignore: avoid_print
      print('TripService.fetchTrips error: $e');
      return const <DeviceTrip>[];
    }
  }

  Stream<List<DeviceTrip>> watchTrips(String deviceId, {int limit = 20}) {
    return FirebaseFirestore.instance
        .collection(_collectionName)
        .where('deviceId', isEqualTo: deviceId)
        .orderBy('startedAt', descending: true)
        .limit(limit)
        .snapshots()
        .handleError((Object error, StackTrace st) {
          // Captura errores del Stream (ej. falta de permisos en Firestore)
          // ignore: avoid_print
          print('TripService.watchTrips stream error: $error\n$st');
          throw error; // Propaga el error a Riverpod/Provider
        })
        .map((QuerySnapshot<Map<String, dynamic>> snapshot) {
          try {
            final List<DeviceTrip> trips = snapshot.docs
              .map((doc) => DeviceTrip.fromFirestore(doc.id, doc.data()))
              .toList(growable: false);
            return trips;
          } catch (e, st) {
            // Error en el mapeo (ej. datos corruptos en el documento)
            // ignore: avoid_print
            print('TripService.watchTrips mapping error: $e\n$st');
            rethrow; // Lanza para que el UI muestre el estado de error
          }
        });
  }
}
