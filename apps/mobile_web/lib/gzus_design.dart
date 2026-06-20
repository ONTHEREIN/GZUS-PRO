import 'package:flutter/material.dart';

extension GzusColorCompat on Color {
  Color withValues({double? alpha, double? red, double? green, double? blue}) {
    return Color.fromARGB(
      alpha == null ? this.alpha : (alpha * 255.0).round().clamp(0, 255),
      red == null ? this.red : (red * 255.0).round().clamp(0, 255),
      green == null ? this.green : (green * 255.0).round().clamp(0, 255),
      blue == null ? this.blue : (blue * 255.0).round().clamp(0, 255),
    );
  }

  double get r => red / 255.0;
  double get g => green / 255.0;
  double get b => blue / 255.0;

  int toARGB32() => value;
}

class GzusColors {
  const GzusColors._();

  static const ink = Color(0xFF17191D);
  static const muted = Color(0xFF6B7280);
  static const canvas = Color(0xFFFAFAF8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSoft = Color(0xFFF4F6FA);
  static const border = Color(0xFFE5E7EB);
  static const blue = Color(0xFF2563EB);
  static const blueDark = Color(0xFF1D4ED8);
  static const blueSoft = Color(0xFFEAF2FF);
  static const green = Color(0xFF059669);
  static const greenSoft = Color(0xFFEAFBF2);
  static const amber = Color(0xFFD97706);
  static const amberSoft = Color(0xFFFFF7E6);
  static const red = Color(0xFFDC2626);
  static const redSoft = Color(0xFFFFECEC);

  static const darkCanvas = Color(0xFF0F1115);
  static const darkSurface = Color(0xFF181B21);
  static const darkSurfaceSoft = Color(0xFF20242C);
  static const darkBorder = Color(0xFF2A2F3A);
}

class GzusRadii {
  const GzusRadii._();

  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
}

ThemeData gzusTheme(Brightness brightness, {double navBarHeight = 76, Color seedColor = GzusColors.blue}) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final textColor = isDark ? const Color(0xFFF5F7FA) : GzusColors.ink;
  final muted = isDark ? const Color(0xFFA4ABB8) : GzusColors.muted;
  final surface = isDark ? GzusColors.darkSurface : GzusColors.surface;
  final surfaceSoft =
      isDark ? GzusColors.darkSurfaceSoft : GzusColors.surfaceSoft;
  final border = isDark ? GzusColors.darkBorder : GzusColors.border;

  final seedSoft = seedColor.withValues(alpha: 0.10);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? GzusColors.darkCanvas : GzusColors.canvas,
    fontFamily: 'Noto Sans SC',
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w900,
        height: 1.12,
        color: textColor,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w900,
        height: 1.18,
        color: textColor,
      ),
      headlineSmall: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w800,
        height: 1.22,
        color: textColor,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        height: 1.25,
        color: textColor,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.32,
        color: textColor,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55, color: textColor),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: textColor),
      bodySmall: TextStyle(fontSize: 12, height: 1.35, color: muted),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: textColor,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: muted,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: muted,
      ),
    ),
    dividerColor: border,
    cardTheme: CardTheme(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GzusRadii.lg),
        side: BorderSide(color: border),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: navBarHeight,
      backgroundColor: surface.withValues(alpha: 0.96),
      indicatorColor: seedSoft,
      labelTextStyle: WidgetStateProperty.all(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: textColor),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          color: states.contains(WidgetState.selected) ? scheme.primary : muted,
          size: 25,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: isDark ? GzusColors.darkCanvas : GzusColors.canvas,
      indicatorColor:
          isDark ? scheme.primary.withValues(alpha: 0.18) : seedSoft,
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: muted),
      selectedLabelTextStyle:
          TextStyle(color: scheme.primary, fontWeight: FontWeight.w800),
      unselectedLabelTextStyle:
          TextStyle(color: muted, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceSoft,
      prefixIconColor: muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GzusRadii.md),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GzusRadii.md),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GzusRadii.md),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GzusRadii.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        side: BorderSide(color: border),
        foregroundColor: textColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GzusRadii.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: scheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GzusRadii.sm),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      selectedColor:
          isDark ? scheme.primary.withValues(alpha: 0.18) : seedSoft,
      backgroundColor: surfaceSoft,
      side: BorderSide(color: border),
      labelStyle: TextStyle(fontWeight: FontWeight.w700, color: textColor),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? GzusColors.darkCanvas : GzusColors.canvas,
      foregroundColor: textColor,
      elevation: 0,
      centerTitle: false,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: textColor,
      contentTextStyle:
          TextStyle(color: isDark ? GzusColors.ink : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GzusRadii.md),
      ),
    ),
  );
}

Color gzusSurface(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? GzusColors.darkSurface
      : GzusColors.surface;
}

Color gzusSurfaceSoft(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? GzusColors.darkSurfaceSoft
      : GzusColors.surfaceSoft;
}

Color gzusBorder(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? GzusColors.darkBorder
      : GzusColors.border;
}

List<BoxShadow> gzusShadow(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.28 : 0.05),
      blurRadius: 28,
      offset: const Offset(0, 16),
    ),
  ];
}
