import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../firebase_options.dart';
import 'fcm_token_sync_service.dart';

const String _alertsChannelId = 'ontacoche_alerts';
const String _alertsChannelName = 'Alertas de OntaCoche';

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

bool _notificationsInitialized = false;

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await _initializeLocalNotifications();
  await _showNotificationFromMessage(message);
}

Future<void> initializeFirebaseMessaging() async {
  final FirebaseMessaging messaging = FirebaseMessaging.instance;

  await _initializeLocalNotifications();

  final NotificationSettings settings = await messaging.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    carPlay: false,
    criticalAlert: false,
    provisional: false,
    sound: true,
  );

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    await _showNotificationFromMessage(message);
  });

  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    debugPrint('opened from FCM notification: ${message.messageId}');
  });

  final RemoteMessage? initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) {
    debugPrint('launched from FCM notification: ${initialMessage.messageId}');
  }

  final String? token = await messaging.getToken();
  debugPrint('FCM token: $token');
  if (token != null && token.isNotEmpty) {
    await syncFcmTokenToFirestore(token);
  }

  messaging.onTokenRefresh.listen((String newToken) async {
    debugPrint('FCM token refreshed: $newToken');
    await syncFcmTokenToFirestore(newToken);
  });

  debugPrint('FCM permission status: ${settings.authorizationStatus}');
}

Future<void> _initializeLocalNotifications() async {
  if (_notificationsInitialized) {
    return;
  }

  const InitializationSettings initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _localNotifications.initialize(initSettings);

  final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
      _localNotifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      _alertsChannelId,
      _alertsChannelName,
      description: 'Notificaciones críticas y alertas del vehículo',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ),
  );

  _notificationsInitialized = true;
}

Future<void> _showNotificationFromMessage(RemoteMessage message) async {
  final String? title = message.notification?.title ?? message.data['title'];
  final String? body = message.notification?.body ?? message.data['body'];

  if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
    return;
  }

  await _localNotifications.show(
    message.hashCode,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _alertsChannelId,
        _alertsChannelName,
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
      ),
    ),
  );
}
