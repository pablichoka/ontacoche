import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String _defaultCollection = 'fcm_tokens';
const String _cachedTokenKey = 'cached_fcm_token';

Future<void> syncFcmTokenToFirestore(String token) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? cached = prefs.getString(_cachedTokenKey);

  if (cached == token) {
    debugPrint('token sync skipped: identical to cached token');
    return;
  }

  final String deviceId = (dotenv.env['DEVICE_ID'] ?? '').trim();

  if (deviceId.isEmpty) {
    debugPrint('token sync skipped: DEVICE_ID is missing in .env');
    return;
  }

  final String collectionName =
      (dotenv.env['FCM_TOKEN_COLLECTION'] ?? _defaultCollection).trim().isEmpty
      ? _defaultCollection
      : (dotenv.env['FCM_TOKEN_COLLECTION'] ?? _defaultCollection).trim();

  final String syncUrl = (dotenv.env['FCM_TOKEN_SYNC_URL'] ?? '').trim();
  final String syncBearer = (dotenv.env['FCM_TOKEN_SYNC_BEARER'] ?? '').trim();

  bool success = false;

  if (syncUrl.isNotEmpty && syncBearer.isNotEmpty) {
    try {
      final http.Response response = await http.post(
        Uri.parse(syncUrl),
        headers: <String, String>{
          'Authorization': 'Bearer $syncBearer',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'token': token,
          'device_id': deviceId,
          'platform': defaultTargetPlatform.name,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('token sync success via backend');
        success = true;
      } else {
        debugPrint(
          'token sync backend failed: ${response.statusCode} ${response.body}',
        );
      }
    } catch (error) {
      debugPrint('token sync backend error: $error');
    }
  }

  if (!success) {
    try {
      await FirebaseFirestore.instance
          .collection(collectionName)
          .doc(token)
          .set(<String, dynamic>{
            'token': token,
            'device_id': deviceId,
            'active': true,
            'platform': defaultTargetPlatform.name,
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      success = true;
    } catch (error) {
      debugPrint('token sync failed: $error');
    }
  }

  if (success) {
    await prefs.setString(_cachedTokenKey, token);
  }
}
