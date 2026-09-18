import 'dart:io';
import 'dart:math' as math;

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/custom_background.dart';

const _imagePathKey = 'theme.customBackground.imagePath';
const _blurSigmaKey = 'theme.customBackground.blurSigma';
const _darknessKey = 'theme.customBackground.darkness';
const _maximumImageBytes = 8 * 1024 * 1024;

class LocalBackgroundStore {
  const LocalBackgroundStore();

  Future<CustomBackgroundSettings?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final imagePath = prefs.getString(_imagePathKey);
    if (imagePath == null || imagePath.isEmpty) return null;

    final imageFile = File(imagePath);
    if (!await imageFile.exists()) {
      await _clearPreferences(prefs);
      throw StateError('本地自定义背景文件不存在，请重新选择背景图片');
    }

    final blurSigma = prefs.getDouble(_blurSigmaKey) ??
        CustomBackgroundSettings.defaultBlurSigma;
    final darkness = prefs.getDouble(_darknessKey) ??
        CustomBackgroundSettings.defaultDarkness;
    CustomBackgroundSettings.validateBlurSigma(blurSigma);
    CustomBackgroundSettings.validateDarkness(darkness);
    return CustomBackgroundSettings(
      imagePath: imagePath,
      blurSigma: blurSigma,
      darkness: darkness,
    );
  }

  Future<CustomBackgroundSettings> replaceImage({
    required XFile image,
    required CustomBackgroundSettings? previous,
  }) async {
    final bytes = await image.readAsBytes();
    if (bytes.length > _maximumImageBytes) {
      throw ArgumentError('图片不能超过 8 MiB，请选择较小的图片');
    }

    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final nonce = math.Random.secure().nextInt(1 << 32);
    final temporaryFile = File(
      '${directory.path}/.custom-background-v1-$stamp-$nonce.tmp',
    );
    final destination = File(
      '${directory.path}/custom-background-v1-$stamp-$nonce.img',
    );
    await temporaryFile.writeAsBytes(bytes, flush: true);
    final savedFile = await temporaryFile.rename(destination.path);
    final settings = CustomBackgroundSettings(
      imagePath: savedFile.path,
      blurSigma: CustomBackgroundSettings.defaultBlurSigma,
      darkness: CustomBackgroundSettings.defaultDarkness,
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      await _savePreferences(prefs, settings);
    } catch (error) {
      await _deleteIfExists(savedFile);
      rethrow;
    }

    final previousPath = previous?.imagePath;
    if (previousPath != null && previousPath != savedFile.path) {
      await _deleteIfExists(File(previousPath));
    }
    return settings;
  }

  Future<void> saveSettings(CustomBackgroundSettings settings) async {
    CustomBackgroundSettings.validateBlurSigma(settings.blurSigma);
    CustomBackgroundSettings.validateDarkness(settings.darkness);
    final imageFile = File(settings.imagePath);
    if (!await imageFile.exists()) {
      throw StateError('本地自定义背景文件不存在，无法保存背景设置');
    }
    final prefs = await SharedPreferences.getInstance();
    await _savePreferences(prefs, settings);
  }

  Future<void> clear(CustomBackgroundSettings settings) async {
    await _deleteIfExists(File(settings.imagePath));
    final prefs = await SharedPreferences.getInstance();
    await _clearPreferences(prefs);
  }

  Future<void> _savePreferences(
    SharedPreferences prefs,
    CustomBackgroundSettings settings,
  ) async {
    final blurSaved = await prefs.setDouble(_blurSigmaKey, settings.blurSigma);
    if (!blurSaved) {
      throw StateError('无法保存本地自定义背景的模糊设置');
    }
    final darknessSaved =
        await prefs.setDouble(_darknessKey, settings.darkness);
    if (!darknessSaved) {
      throw StateError('无法保存本地自定义背景的暗度设置');
    }
    final pathSaved = await prefs.setString(_imagePathKey, settings.imagePath);
    if (!pathSaved) {
      throw StateError('无法保存本地自定义背景图片路径');
    }
  }

  Future<void> _clearPreferences(SharedPreferences prefs) async {
    await prefs.remove(_imagePathKey);
    await prefs.remove(_blurSigmaKey);
    await prefs.remove(_darknessKey);
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}
