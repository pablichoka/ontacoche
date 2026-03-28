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
              .orderBy('startTime', descending: true)
              .limit(limit)
              .get();

      return snapshot.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                Trip.fromFirestore(doc.id, doc.data()),
          )
          .toList(growable: false);
    } catch (e) {
      return const <Trip>[];
    }
  }

  Stream<List<Trip>> watchTrips(String deviceIdent, {int limit = 20}) {
    return FirebaseFirestore.instance
        .collection(_collectionName)
        .where('deviceIdent', isEqualTo: deviceIdent)
        .orderBy('startTime', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => Trip.fromFirestore(doc.id, doc.data()))
              .toList(growable: false);
        });
  }
}
