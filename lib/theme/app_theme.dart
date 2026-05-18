import 'package:flutter/material.dart';

/// Builds the complete theme for the app with customizable seed color
/// Supports both light and dark brightness modes
/// Creates consistent styling for all UI components (cards, buttons, inputs, etc.)
ThemeData buildAlarmTheme(Color seedColor, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  final base = ThemeData.from(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF7F8FC),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      foregroundColor: scheme.onSurface,
    ),
    cardTheme: base.cardTheme.copyWith(
      color: isDark ? const Color(0xFF1F1B24) : Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      bodyColor: scheme.onPrimary,
      displayColor: scheme.onPrimary,
    ),
    iconTheme: base.iconTheme.copyWith(color: scheme.onSurface),
    dividerColor: scheme.outline,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF141214) : const Color(0xFFF1F3F8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 153)),
      labelStyle: TextStyle(color: scheme.onSurface),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: isDark ? scheme.surface : Colors.white,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurface,
      showUnselectedLabels: true,
    ),
  );
}
