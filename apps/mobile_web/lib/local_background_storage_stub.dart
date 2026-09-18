import 'package:image_picker/image_picker.dart';

import 'models/custom_background.dart';

class LocalBackgroundStore {
  const LocalBackgroundStore();

  Future<CustomBackgroundSettings?> load() {
    return Future<CustomBackgroundSettings?>.error(
      UnsupportedError('当前平台不支持本地自定义背景'),
    );
  }

  Future<CustomBackgroundSettings> replaceImage({
    required XFile image,
    required CustomBackgroundSettings? previous,
  }) {
    return Future<CustomBackgroundSettings>.error(
      UnsupportedError('当前平台不支持本地自定义背景'),
    );
  }

  Future<void> saveSettings(CustomBackgroundSettings settings) {
    return Future<void>.error(
      UnsupportedError('当前平台不支持本地自定义背景'),
    );
  }

  Future<void> clear(CustomBackgroundSettings settings) {
    return Future<void>.error(
      UnsupportedError('当前平台不支持本地自定义背景'),
    );
  }
}
