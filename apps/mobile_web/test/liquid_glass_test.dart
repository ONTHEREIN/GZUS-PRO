import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/widgets/liquid_glass.dart';

void main() {
  tearDown(() {
    LiquidGlassPlatform.setCapabilitiesForTest(
      const LiquidGlassCapabilities.unsupported(),
    );
  });

  test('能力响应必须包含所需布尔字段', () {
    expect(
      () => LiquidGlassCapabilities.fromMessage(<String, Object>{
        'systemGlassSupported': true,
      }),
      throwsArgumentError,
    );
  });

  testWidgets('未检测到系统材质时不启用高开销背景模糊', (tester) async {
    LiquidGlassPlatform.setCapabilitiesForTest(
      const LiquidGlassCapabilities.unsupported(),
    );

    await tester.pumpWidget(_testApp());

    expect(find.byType(LiquidGlassSurface), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('降低透明度时使用不透明表面', (tester) async {
    LiquidGlassPlatform.setCapabilitiesForTest(
      const LiquidGlassCapabilities(
        systemGlassSupported: false,
        reduceTransparency: true,
      ),
    );

    await tester.pumpWidget(_testApp());

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('iOS 系统玻璃可用时不遮住 Flutter 内容', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    LiquidGlassPlatform.setCapabilitiesForTest(
      const LiquidGlassCapabilities(
        systemGlassSupported: true,
        reduceTransparency: false,
      ),
    );

    await tester.pumpWidget(_testApp());

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

Widget _testApp() {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: LiquidGlassSurface(
          padding: const EdgeInsets.all(16),
          borderRadius: BorderRadius.circular(20),
          material: LiquidGlassMaterial.regular,
          semanticsLabel: '测试玻璃区域',
          child: const Text('内容'),
        ),
      ),
    ),
  );
}
