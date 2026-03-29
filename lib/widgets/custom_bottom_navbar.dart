import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class CustomBottomNavbar extends StatelessWidget {
  const CustomBottomNavbar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.unseenAlertsCount = 0,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final int unseenAlertsCount;

  @override
  Widget build(BuildContext context) {
    final List<_NavItemData> items = <_NavItemData>[
      const _NavItemData(
        icon: Icons.map_outlined,
        selectedIcon: Icons.map_rounded,
      ),
      const _NavItemData(
        icon: Icons.history_outlined,
        selectedIcon: Icons.history_rounded,
      ),
      const _NavItemData(
        icon: Icons.notifications_none_rounded,
        selectedIcon: Icons.notifications_rounded,
      ),
      const _NavItemData(
        icon: Icons.fence_outlined,
        selectedIcon: Icons.fence_rounded,
      ),
      const _NavItemData(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings_rounded,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 72),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          elevation: 8,
          color: AppColors.surfaceContainerLowest.withValues(alpha: 0.90),
          borderRadius: BorderRadius.circular(999),
          shadowColor: AppColors.secondary.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List<Widget>.generate(items.length, (int index) {
                final _NavItemData item = items[index];
                final bool isSelected = index == selectedIndex;
                final Widget icon = Icon(
                  isSelected ? item.selectedIcon : item.icon,
                  size: 28,
                  color: isSelected ? AppColors.brand : AppColors.muted,
                );

                return Padding(
                  padding: EdgeInsets.only(
                    right: index == items.length - 1 ? 0 : 6,
                  ),
                  child: _NavbarButton(
                    isSelected: isSelected,
                    onTap: () => onDestinationSelected(index),
                    child: index == 2
                        ? Badge(
                            isLabelVisible: unseenAlertsCount > 0,
                            label: Text(unseenAlertsCount.toString()),
                            child: icon,
                          )
                        : icon,
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavbarButton extends StatelessWidget {
  const _NavbarButton({
    required this.isSelected,
    required this.onTap,
    required this.child,
  });

  final bool isSelected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? AppColors.brand.withValues(alpha: 0.1)
          : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(width: 46, height: 46, child: Center(child: child)),
      ),
    );
  }
}

class _NavItemData {
  const _NavItemData({required this.icon, required this.selectedIcon});

  final IconData icon;
  final IconData selectedIcon;
}
