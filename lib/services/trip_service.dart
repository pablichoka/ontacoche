import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/trip.dart';

class TripService {
  TripService({String? collectionName})
      : _collectionName = collectionName ?? 'trips';

  final String _collectionName;

  Future<List<Trip>> fetchTrips(String deviceIdent, {int limit = 20}) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection(_collectionName)
              .where('deviceIdent', isEqualTo: deviceIdent)
              .limit(limit)
              .get();

      final List<Trip> trips = snapshot.docs
          .map(
            (doc) => Trip.fromFirestore(doc.id, doc.data()),
          )
          .toList(); // CUIDADO: Quitado el growable: false para permitir el sort()

      // Sort client-side by startTime descending to avoid requiring a
      // composite index on (deviceIdent, startTime).
      trips.sort((a, b) => b.startTime.compareTo(a.startTime));
      return trips;
    } catch (e) {
      // Log the error so it's visible during debugging instead of silently
      // returning an empty list.
      // ignore: avoid_print
      print('TripService.fetchTrips error: $e');
      return const <Trip>[];
    }
  }

  Stream<List<Trip>> watchTrips(String deviceIdent, {int limit = 20}) {
    return FirebaseFirestore.instance
        .collection(_collectionName)
        .where('deviceIdent', isEqualTo: deviceIdent)
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
            final List<Trip> trips = snapshot.docs
                .map((doc) => Trip.fromFirestore(doc.id, doc.data()))
                .toList(); // Sin growable: false para permitir reordenar
            
            trips.sort((a, b) => b.startTime.compareTo(a.startTime));
            return trips;
          } catch (e, st) {
            // Error en el mapeo (ej. datos corruptos en el documento)
            // ignore: avoid_print
            print('TripService.watchTrips mapping error: $e\n$st');
            throw e; // Lanza para que el UI muestre el estado de error
          }
        });
  }
}