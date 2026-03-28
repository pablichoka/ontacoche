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
      // Log the error so it's visible during debugging instead of silently
      // returning an empty list. This helps detect Firestore permission,
      // index or type errors that would otherwise be hidden.
      // ignore: avoid_print
      print('TripService.fetchTrips error: $e');
      return const <Trip>[];
    }
  }

  Stream<List<Trip>> watchTrips(String deviceIdent, {int limit = 20}) {
    final Stream<QuerySnapshot<Map<String, dynamic>>> baseStream =
        FirebaseFirestore.instance
            .collection(_collectionName)
            .where('deviceIdent', isEqualTo: deviceIdent)
            .orderBy('startTime', descending: true)
            .limit(limit)
            .snapshots();

    // Attach an error handler to surface Firestore errors in logs and avoid
    // crashing the stream consumer with an uncaught error. The UI will show
    // the error state; printing it helps debugging (e.g. missing index).
    return baseStream
        .handleError((Object e, StackTrace st) {
          // ignore: avoid_print
          print('TripService.watchTrips stream error: $e\n$st');
        })
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => Trip.fromFirestore(doc.id, doc.data()))
              .toList(growable: false);
        });
  }
}
