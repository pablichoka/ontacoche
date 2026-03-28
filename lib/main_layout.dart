import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/history_screen.dart';
import 'screens/map_screen.dart';
import 'screens/alerts_screen.dart';
import 'screens/geofence_manager_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/custom_bottom_navbar.dart';
import 'providers/telemetry_provider.dart';
import 'models/device_alert.dart';

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    MapScreen(),
    HistoryScreen(),
    AlertsScreen(),
    GeofenceManagerScreen(),
    SettingsScreen(),
  ];

  void _onDestinationSelected(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: Consumer(
        builder: (context, ref, _) {
          final int count = ref.watch(alertsUnseenCountProvider);
          final List<DeviceAlert> currentAlerts =
              ref.watch(alertsHistoryProvider).valueOrNull ??
              const <DeviceAlert>[];
          return CustomBottomNavbar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (int idx) {
              if (idx == 2) {
                ref.read(acknowledgeAlertsViewUseCaseProvider)(currentAlerts);
                // mark alerts as seen when opening the alerts tab
                ref.read(markAllAlertsSeenUseCaseProvider)().catchError((_) {});
              }
              _onDestinationSelected(idx);
            },
            unseenAlertsCount: count,
          );
        },
      ),
    );
  }
}
