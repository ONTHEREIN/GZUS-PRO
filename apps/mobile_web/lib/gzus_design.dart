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

  // 中性色
  static const ink = Color(0xFF17191D);
  static const muted = Color(0xFF6B7280);
  static const canvas = Color(0xFFFAFAF8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSoft = Color(0xFFF4F6FA);
  static const border = Color(0xFFE5E7EB);

  // 深色模式中性色（增强层次）
  static const darkCanvas = Color(0xFF0B0D10);
  static const darkSurface = Color(0xFF15171C);
  static const darkSurfaceSoft = Color(0xFF1E2128);
  static const darkElevated = Color(0xFF252A33);
  static const darkBorder = Color(0xFF2A2F3A);

  // 预设主题色板：8 个精心挑选的品牌色
  static const blue = Color(0xFF2563EB);
  static const teal = Color(0xFF0891B2);
  static const green = Color(0xFF059669);
  static const amber = Color(0xFFEA580C);
  static const purple = Color(0xFF7C3AED);
  static const rose = Color(0xFFDB2777);
  static const slate = Color(0xFF475569);
  static const indigo = Color(0xFF4F46E5);

  // 主题色对应的强调背景（浅色模式）
  static const blueSoft = Color(0xFFEAF2FF);
  static const tealSoft = Color(0xFFE0F7FA);
  static const greenSoft = Color(0xFFEAFBF2);
  static const amberSoft = Color(0xFFFFF7E6);
  static const purpleSoft = Color(0xFFF3E8FF);
  static const roseSoft = Color(0xFFFFE4E6);
  static const slateSoft = Color(0xFFF1F5F9);
  static const indigoSoft = Color(0xFFE0E7FF);

  // 语义色
  static const red = Color(0xFFDC2626);
  static const redSoft = Color(0xFFFFECEC);
  static const info = Color(0xFF0EA5E9);
  static const infoSoft = Color(0xFFE0F2FE);

  /// 预设主题色列表，供用户选择。
  static const List<Color> presetThemeColors = [
    blue,
    teal,
    green,
    indigo,
    purple,
    rose,
    amber,
    slate,
  ];

  /// 预设主题色名称（与 presetThemeColors 顺序一致）。
  static const List<String> presetThemeColorNames = [
    '默认蓝',
    '青色',
    '绿色',
    '靛蓝',
    '紫色',
    '玫瑰',
    '橙色',
    '石墨',
  ];

  /// 模块语义色：用于首页各模块图标背景、左侧色条等。
  static const moduleSchedule = blue;
  static const moduleGrades = green;
  static const moduleAttendance = amber;
  static const moduleEcard = teal;
  static const moduleExams = red;
  static const moduleNotices = purple;
  static const moduleApplications = indigo;
  static const moduleCredits = rose;

  /// 返回某个主题色的柔和背景色（浅色模式用）。
  static Color softColorOf(Color color) {
    final map = <Color, Color>{
      blue: blueSoft,
      teal: tealSoft,
      green: greenSoft,
      amber: amberSoft,
      purple: purpleSoft,
      rose: roseSoft,
      slate: slateSoft,
      indigo: indigoSoft,
    };
    return map[color] ?? color.withValues(alpha: 0.10);
  }
}

class GzusRadii {
  const GzusRadii._();

  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
}

ThemeData gzusTheme(Brightness brightness,
    {double navBarHeight = 76, Color seedColor = GzusColors.blue}) {
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
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.15,
        color: textColor,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.20,
        color: textColor,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.24,
        color: textColor,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.28,
        color: textColor,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: textColor,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.60,
        color: textColor,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: textColor,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: muted,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: textColor,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
    ),
    dividerColor: border,
    cardTheme: CardThemeData(
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
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          color: states.contains(WidgetState.selected) ? scheme.primary : muted,
          size: 24,
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
          TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle:
          TextStyle(color: muted, fontWeight: FontWeight.w500),
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
      selectedColor: isDark ? scheme.primary.withValues(alpha: 0.18) : seedSoft,
      backgroundColor: surfaceSoft,
      side: BorderSide(color: border),
      labelStyle: TextStyle(fontWeight: FontWeight.w600, color: textColor),
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

Color gzusSurfaceElevated(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? GzusColors.darkElevated
      : GzusColors.surface;
}

/// 柔和投影：浅色模式下用黑色半透明，深色模式下用主色微光避免阴影不可见。
List<BoxShadow> gzusShadow(BuildContext context, {bool elevated = false}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final primary = Theme.of(context).colorScheme.primary;
  return [
    BoxShadow(
      color: dark
          ? primary.withValues(alpha: elevated ? 0.18 : 0.08)
          : Colors.black.withValues(alpha: elevated ? 0.10 : 0.05),
      blurRadius: elevated ? 32 : 28,
      offset: const Offset(0, 16),
    ),
  ];
}

/// OneGZUS 命名文字样式。
///
/// 页面应优先使用 [ThemeData.textTheme] 中的语义样式；对于局部需要统一微调的场景，
/// 使用本类可以减少硬编码 `fontSize:` 和重复 `TextStyle`。
abstract final class GzusTextStyles {
  const GzusTextStyles._();

  // 页面级标题
  static TextStyle? pageTitle(BuildContext context) {
    return Theme.of(context).textTheme.headlineSmall;
  }

  static TextStyle? sectionTitle(BuildContext context) {
    return Theme.of(context).textTheme.titleLarge;
  }

  // 卡片与模块
  static TextStyle? cardTitle(BuildContext context) {
    return Theme.of(context).textTheme.titleMedium;
  }

  static TextStyle? cardSubtitle(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall;
  }

  static TextStyle? moduleTitle(BuildContext context) {
    return Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        );
  }

  // 指标与数据
  static TextStyle? metricValue(BuildContext context) {
    return Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        );
  }

  static TextStyle? metricLabel(BuildContext context) {
    return Theme.of(context).textTheme.labelMedium;
  }

  static TextStyle? statisticValue(BuildContext context) {
    return Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );
  }

  static TextStyle? statisticLabel(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall;
  }

  // 列表与正文
  static TextStyle? listTitle(BuildContext context) {
    return Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        );
  }

  static TextStyle? listSubtitle(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall;
  }

  static TextStyle? bodyEmphasis(BuildContext context) {
    return Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        );
  }

  // 标签与辅助
  static TextStyle? buttonLabel(BuildContext context) {
    return Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        );
  }

  static TextStyle? caption(BuildContext context) {
    return Theme.of(context).textTheme.labelSmall;
  }

  static TextStyle? overline(BuildContext context) {
    return Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        );
  }
}
