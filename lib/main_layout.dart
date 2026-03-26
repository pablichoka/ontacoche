import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/history_screen.dart';
import 'screens/map_screen.dart';
import 'screens/alerts_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/custom_bottom_navbar.dart';
import 'providers/telemetry_provider.dart';

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
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: Consumer(
        builder: (context, ref, _) {
          final int count = ref.watch(alertsUnseenCountProvider);
          final int displayedCount = _currentIndex == 2 ? 0 : count;
          return CustomBottomNavbar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (int idx) {
              if (idx == 2) {
                // mark alerts as seen when opening the alerts tab
                ref.read(markAllAlertsSeenUseCaseProvider)().catchError((_) {});
              }
              _onDestinationSelected(idx);
            },
            unseenAlertsCount: displayedCount,
          );
        },
      ),
    );
  }
}
