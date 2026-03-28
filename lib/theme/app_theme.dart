import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get dark {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.dark,
      surface: AppColors.surface,
      primary: AppColors.brand,
      secondary: AppColors.secondary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppColors.foreground,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceContainerLow,
        contentTextStyle: const TextStyle(color: AppColors.foreground),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      textTheme: const TextTheme(
        titleMedium: TextStyle(
          color: AppColors.foreground,
          fontWeight: FontWeight.w700,
        ),
        bodyMedium: TextStyle(color: AppColors.foreground),
        bodySmall: TextStyle(color: AppColors.muted),
        labelMedium: TextStyle(
          color: AppColors.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
