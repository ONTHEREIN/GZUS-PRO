import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gzus_design.dart';

const _nativeLiquidTabBarViewType = 'cn.gzus.pro/native-liquid-tab-bar';
const _liquidGlassChannelName = 'cn.gzus.pro/liquid-glass';

enum LiquidGlassMaterial { regular, clear }

class LiquidGlassCapabilities {
  const LiquidGlassCapabilities({
    required this.systemGlassSupported,
    required this.reduceTransparency,
  });

  const LiquidGlassCapabilities.unsupported()
      : systemGlassSupported = false,
        reduceTransparency = false;

  final bool systemGlassSupported;
  final bool reduceTransparency;

  factory LiquidGlassCapabilities.fromMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      throw ArgumentError.value(
        message,
        'message',
        '液态玻璃能力响应必须为键值映射。',
      );
    }
    final supported = message['systemGlassSupported'];
    final reduceTransparency = message['reduceTransparency'];
    if (supported is! bool || reduceTransparency is! bool) {
      throw ArgumentError.value(
        message,
        'message',
        '液态玻璃能力响应缺少布尔字段。',
      );
    }
    return LiquidGlassCapabilities(
      systemGlassSupported: supported,
      reduceTransparency: reduceTransparency,
    );
  }
}

/// iOS 原生材质能力。未完成探测前保持 Flutter 材质，避免首帧空白。
abstract final class LiquidGlassPlatform {
  LiquidGlassPlatform._();

  static const MethodChannel _channel = MethodChannel(_liquidGlassChannelName);
  static final ValueNotifier<LiquidGlassCapabilities> capabilities =
      ValueNotifier(const LiquidGlassCapabilities.unsupported());
  static bool _initialized = false;
  static ValueChanged<int>? _nativeTabSelectionHandler;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_isIos) return;

    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final response = await _channel.invokeMethod<Object?>('capabilities');
      capabilities.value = LiquidGlassCapabilities.fromMessage(response);
    } on MissingPluginException catch (error) {
      debugPrint('液态玻璃原生通道不可用：$error');
    } on PlatformException catch (error) {
      debugPrint('液态玻璃能力检测失败：${error.code} ${error.message}');
    }
  }

  static void setNativeTabSelectionHandler(ValueChanged<int> handler) {
    _nativeTabSelectionHandler = handler;
  }

  static Future<void> updateNativeTabBarSelected({
    required int selectedIndex,
  }) async {
    if (!_isIos) return;
    try {
      await _channel.invokeMethod<bool>(
        'updateNativeTabBarSelected',
        <String, Object>{'selectedIndex': selectedIndex},
      );
    } on MissingPluginException catch (error) {
      debugPrint('原生底栏通道不可用：$error');
    } on PlatformException catch (error) {
      debugPrint('原生底栏状态同步失败：${error.code} ${error.message}');
    }
  }

  static Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'capabilitiesChanged':
        capabilities.value =
            LiquidGlassCapabilities.fromMessage(call.arguments);
        return null;
      case 'nativeTabSelected':
        final selectedIndex = call.arguments;
        if (selectedIndex is! int) {
          throw ArgumentError.value(
            selectedIndex,
            'arguments',
            '原生底栏选择事件必须携带索引。',
          );
        }
        final handler = _nativeTabSelectionHandler;
        if (handler == null) {
          throw StateError('原生底栏选择事件没有 Flutter 处理器。');
        }
        handler(selectedIndex);
        return null;
    }
    throw MissingPluginException('不支持的液态玻璃原生方法：${call.method}');
  }

  @visibleForTesting
  static void setCapabilitiesForTest(LiquidGlassCapabilities value) {
    capabilities.value = value;
  }
}

/// iOS 26+ 原生 UITabBar。
///
/// 选中胶囊完全由 UIKit 渲染；Flutter 只提供页面状态和项目内容。
class NativeIosLiquidTabBar extends StatefulWidget {
  const NativeIosLiquidTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.tintColor,
  });

  final List<NativeLiquidTabBarItem> tabs;
  final int selected;
  final ValueChanged<int> onChanged;
  final Color tintColor;

  @override
  State<NativeIosLiquidTabBar> createState() => _NativeIosLiquidTabBarState();
}

class NativeLiquidTabBarItem {
  const NativeLiquidTabBarItem({
    required this.title,
    required this.systemImageName,
  });

  final String title;
  final String systemImageName;

  Map<String, String> toMessage() => <String, String>{
        'title': title,
        'systemImageName': systemImageName,
      };
}

class _NativeIosLiquidTabBarState extends State<NativeIosLiquidTabBar> {
  @override
  void initState() {
    super.initState();
    LiquidGlassPlatform.setNativeTabSelectionHandler(widget.onChanged);
  }

  @override
  void didUpdateWidget(covariant NativeIosLiquidTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    LiquidGlassPlatform.setNativeTabSelectionHandler(widget.onChanged);
    if (widget.selected != oldWidget.selected) {
      unawaited(LiquidGlassPlatform.updateNativeTabBarSelected(
        selectedIndex: widget.selected,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '底部导航栏',
      container: true,
      child: UiKitView(
        key: ValueKey<String>(
          'native-liquid-tab-bar:'
          '${widget.tabs.map((tab) => tab.title).join(',')}:'
          '${widget.tintColor.toARGB32()}',
        ),
        viewType: _nativeLiquidTabBarViewType,
        creationParams: <String, Object>{
          'selectedIndex': widget.selected,
          'tintColor': widget.tintColor.toARGB32(),
          'items':
              widget.tabs.map((tab) => tab.toMessage()).toList(growable: false),
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}

/// iOS 原生系统玻璃与 Flutter 玻璃拟态的统一表面。
///
/// 容器内容由 Flutter 绘制。iOS 平台视图无法可靠地位于 Flutter 内容下方，
/// 因此表面始终使用 Flutter 玻璃底材，避免原生效果遮住登录页和页面内容。
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    required this.padding,
    required this.borderRadius,
    required this.material,
    required this.semanticsLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final LiquidGlassMaterial material;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LiquidGlassCapabilities>(
      valueListenable: LiquidGlassPlatform.capabilities,
      builder: (context, capabilities, _) {
        // BackdropFilter 会让 GPU 对覆盖区域重复采样并模糊背景。仅在 iOS
        // 原生系统玻璃可用时保留这一效果，其余平台使用半透明渐变以避免掉帧。
        final useBackdropBlur = !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.iOS &&
            capabilities.systemGlassSupported &&
            !capabilities.reduceTransparency;
        final disableAnimations = MediaQuery.disableAnimationsOf(context);
        final shadow = disableAnimations
            ? const <BoxShadow>[]
            : gzusShadow(context, elevated: true);
        return Semantics(
          label: semanticsLabel,
          container: true,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              boxShadow: shadow,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: _FlutterGlassBackdrop(
                      borderRadius: borderRadius,
                      material: material,
                      opaque: capabilities.reduceTransparency,
                      useBackdropBlur: useBackdropBlur,
                    ),
                  ),
                ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FlutterGlassBackdrop extends StatelessWidget {
  const _FlutterGlassBackdrop({
    required this.borderRadius,
    required this.material,
    required this.opaque,
    required this.useBackdropBlur,
  });

  final BorderRadius borderRadius;
  final LiquidGlassMaterial material;
  final bool opaque;
  final bool useBackdropBlur;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final clear = material == LiquidGlassMaterial.clear;
    final surface = gzusSurface(context);
    final fillAlpha = clear ? (dark ? 0.28 : 0.36) : (dark ? 0.46 : 0.52);
    final decoration = BoxDecoration(
      color: opaque ? surface : null,
      gradient: opaque
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                surface.withValues(alpha: fillAlpha),
                Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: dark ? 0.10 : 0.07),
                surface.withValues(alpha: fillAlpha * 0.64),
              ],
            ),
      borderRadius: borderRadius,
      border: Border.all(
        color: opaque
            ? gzusBorder(context)
            : Colors.white.withValues(alpha: dark ? 0.14 : 0.62),
      ),
    );
    final backdrop = DecoratedBox(decoration: decoration);
    return ClipRRect(
      borderRadius: borderRadius,
      child: useBackdropBlur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: backdrop,
            )
          : backdrop,
    );
  }
}

/// 覆盖在玻璃底座上的选中胶囊，用于导航等可切换控件。
class LiquidGlassSelectionIndicator extends StatelessWidget {
  const LiquidGlassSelectionIndicator({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.accentColor,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LiquidGlassCapabilities>(
      valueListenable: LiquidGlassPlatform.capabilities,
      builder: (context, capabilities, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final opaque = capabilities.reduceTransparency;
        return Container(
          decoration: BoxDecoration(
            color: opaque
                ? accentColor.withValues(alpha: dark ? 0.24 : 0.14)
                : null,
            gradient: opaque
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      Colors.white.withValues(alpha: dark ? 0.18 : 0.62),
                      accentColor.withValues(alpha: dark ? 0.28 : 0.16),
                      Colors.white.withValues(alpha: dark ? 0.08 : 0.30),
                    ],
                  ),
            borderRadius: borderRadius,
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.22 : 0.76),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: accentColor.withValues(alpha: dark ? 0.24 : 0.16),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.18 : 0.06),
                blurRadius: 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}

/// 为玻璃材质提供极轻的背景层次；非 iOS 平台保持透明。
class LiquidGlassAmbientBackdrop extends StatelessWidget {
  const LiquidGlassAmbientBackdrop({super.key, required this.seedColor});

  final Color seedColor;

  @override
  Widget build(BuildContext context) {
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    if (!isIos) return const SizedBox.expand();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.72, -0.92),
                radius: 1.25,
                colors: <Color>[
                  seedColor.withValues(alpha: dark ? 0.28 : 0.20),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.9, 0.78),
                radius: 1.08,
                colors: <Color>[
                  Theme.of(context)
                      .colorScheme
                      .tertiary
                      .withValues(alpha: dark ? 0.20 : 0.13),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showLiquidGlassDialog<T>({
  required BuildContext context,
  required String semanticsLabel,
  required WidgetBuilder builder,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.48),
    builder: (dialogContext) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: LiquidGlassSurface(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          borderRadius: BorderRadius.circular(GzusRadii.lg),
          material: LiquidGlassMaterial.regular,
          semanticsLabel: semanticsLabel,
          child: builder(dialogContext),
        ),
      ),
    ),
  );
}

Future<T?> showLiquidGlassModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: builder,
  );
}
