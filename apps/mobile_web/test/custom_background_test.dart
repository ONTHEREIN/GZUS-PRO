import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/local_background_storage.dart';
import 'package:gzus_pro_mobile_web/models/custom_background.dart';
import 'package:gzus_pro_mobile_web/widgets/liquid_glass.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CustomBackgroundSettings', () {
    test('序列化后可以恢复完整配置', () {
      const settings = CustomBackgroundSettings(
        imagePath: '/tmp/background.img',
        blurSigma: 16,
        darkness: 0.45,
      );

      final restored = CustomBackgroundSettings.fromJson(settings.toJson());

      expect(restored, settings);
    });

    test('提供计划中的默认值和调节范围', () {
      expect(CustomBackgroundSettings.defaultBlurSigma, 8);
      expect(CustomBackgroundSettings.defaultDarkness, 0.2);
      expect(CustomBackgroundSettings.minBlurSigma, 0);
      expect(CustomBackgroundSettings.maxBlurSigma, 24);
      expect(CustomBackgroundSettings.minDarkness, 0);
      expect(CustomBackgroundSettings.maxDarkness, 0.8);
    });

    test('拒绝超出范围的调节值', () {
      expect(
        () => CustomBackgroundSettings.fromJson(<String, Object?>{
          'imagePath': '/tmp/background.img',
          'blurSigma': 25,
          'darkness': 0.2,
        }),
        throwsArgumentError,
      );
      expect(
        () => CustomBackgroundSettings.fromJson(<String, Object?>{
          'imagePath': '/tmp/background.img',
          'blurSigma': 8,
          'darkness': 0.81,
        }),
        throwsArgumentError,
      );
    });
  });

  group('LocalBackgroundStore', () {
    late Directory supportDirectory;
    late PathProviderPlatform previousPathProvider;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      supportDirectory =
          await Directory.systemTemp.createTemp('gzus-background-test-');
      previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(supportDirectory.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test('保存、恢复、更换和删除背景图片', () async {
      const firstBytes = <int>[1, 2, 3, 4];
      const secondBytes = <int>[5, 6, 7, 8];
      const store = LocalBackgroundStore();

      final first = await store.replaceImage(
        image:
            XFile.fromData(Uint8List.fromList(firstBytes), name: 'first.png'),
        previous: null,
      );
      expect(await File(first.imagePath).readAsBytes(), firstBytes);

      final adjusted = first.withBlurSigma(14).withDarkness(0.4);
      await store.saveSettings(adjusted);
      expect(await store.load(), adjusted);

      final second = await store.replaceImage(
        image:
            XFile.fromData(Uint8List.fromList(secondBytes), name: 'second.png'),
        previous: adjusted,
      );
      expect(await File(second.imagePath).readAsBytes(), secondBytes);
      expect(await File(first.imagePath).exists(), isFalse);
      expect(second.blurSigma, CustomBackgroundSettings.defaultBlurSigma);
      expect(second.darkness, CustomBackgroundSettings.defaultDarkness);

      await store.clear(second);
      expect(await store.load(), isNull);
      expect(await File(second.imagePath).exists(), isFalse);
    });

    test('拒绝超过 8 MiB 的图片', () async {
      const store = LocalBackgroundStore();
      final oversized = Uint8List(8 * 1024 * 1024 + 1);

      await expectLater(
        store.replaceImage(
          image: XFile.fromData(oversized, name: 'oversized.png'),
          previous: null,
        ),
        throwsArgumentError,
      );
    });
  });

  testWidgets('自定义背景层根据设置启用图片模糊和暗度覆盖', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.light),
        home: const SizedBox.expand(
          child: LiquidGlassAmbientBackdrop(
            seedColor: GzusColors.blue,
            background: CustomBackgroundSettings(
              imagePath: '/tmp/gzus-test-background.img',
              blurSigma: 12,
              darkness: 0.4,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
      find.byKey(const ValueKey('custom-background-darkness-overlay')),
      findsOneWidget,
    );
  });
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}
