import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background/mqtt_background_service.dart';
import 'firebase_options.dart';
import 'main_layout.dart';
import 'services/firebase_messaging_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await initializeFirebaseMessaging();
  await dotenv.load(fileName: '.env');
  await initializeBackgroundTrackingService();
  runApp(const ProviderScope(child: OntaCocheApp()));
}

class OntaCocheApp extends StatelessWidget {
  const OntaCocheApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OntaCoche',
      theme: AppTheme.light,
      home: const MainLayout(),
    );
  }
}