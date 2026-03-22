import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

const String _defaultCollection = 'fcm_tokens';

Future<void> syncFcmTokenToFirestore(String token) async {
  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();

  if (deviceId.isEmpty) {
    debugPrint('token sync skipped: DEVICE_ID is missing in .env');
    return;
  }

  final String collectionName =
      (dotenv.env['FCM_TOKEN_COLLECTION'] ?? _defaultCollection).trim().isEmpty
      ? _defaultCollection
      : (dotenv.env['FCM_TOKEN_COLLECTION'] ?? _defaultCollection).trim();

  try {
    await FirebaseFirestore.instance.collection(collectionName).doc(token).set(
      <String, dynamic>{
        'token': token,
        'device_id': deviceId,
        'active': true,
        'platform': defaultTargetPlatform.name,
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  } catch (error) {
    debugPrint('token sync failed: $error');
  }
}
