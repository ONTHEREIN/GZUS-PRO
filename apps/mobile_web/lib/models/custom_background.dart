/// 移动端自定义背景配置。
class CustomBackgroundSettings {
  const CustomBackgroundSettings({
    required this.imagePath,
    required this.blurSigma,
    required this.darkness,
  });

  static const double defaultBlurSigma = 8;
  static const double defaultDarkness = 0.2;
  static const double minBlurSigma = 0;
  static const double maxBlurSigma = 24;
  static const double minDarkness = 0;
  static const double maxDarkness = 0.8;

  final String imagePath;
  final double blurSigma;
  final double darkness;

  CustomBackgroundSettings withImagePath(String path) {
    return CustomBackgroundSettings(
      imagePath: path,
      blurSigma: blurSigma,
      darkness: darkness,
    );
  }

  CustomBackgroundSettings withBlurSigma(double value) {
    return CustomBackgroundSettings(
      imagePath: imagePath,
      blurSigma: value,
      darkness: darkness,
    );
  }

  CustomBackgroundSettings withDarkness(double value) {
    return CustomBackgroundSettings(
      imagePath: imagePath,
      blurSigma: blurSigma,
      darkness: value,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'imagePath': imagePath,
      'blurSigma': blurSigma,
      'darkness': darkness,
    };
  }

  factory CustomBackgroundSettings.fromJson(Map<String, Object?> json) {
    final imagePath = json['imagePath'];
    final blurSigma = json['blurSigma'];
    final darkness = json['darkness'];
    if (imagePath is! String || imagePath.isEmpty) {
      throw const FormatException('自定义背景缺少有效图片路径');
    }
    if (blurSigma is! num || darkness is! num) {
      throw const FormatException('自定义背景调节值格式无效');
    }
    _validateBlurSigma(blurSigma.toDouble());
    _validateDarkness(darkness.toDouble());
    return CustomBackgroundSettings(
      imagePath: imagePath,
      blurSigma: blurSigma.toDouble(),
      darkness: darkness.toDouble(),
    );
  }

  static void validateBlurSigma(double value) {
    _validateBlurSigma(value);
  }

  static void validateDarkness(double value) {
    _validateDarkness(value);
  }

  static void _validateBlurSigma(double value) {
    if (!value.isFinite || value < minBlurSigma || value > maxBlurSigma) {
      throw ArgumentError.value(
        value,
        'blurSigma',
        '模糊值必须在 $minBlurSigma 到 $maxBlurSigma 之间',
      );
    }
  }

  static void _validateDarkness(double value) {
    if (!value.isFinite || value < minDarkness || value > maxDarkness) {
      throw ArgumentError.value(
        value,
        'darkness',
        '暗度必须在 $minDarkness 到 $maxDarkness 之间',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    return other is CustomBackgroundSettings &&
        other.imagePath == imagePath &&
        other.blurSigma == blurSigma &&
        other.darkness == darkness;
  }

  @override
  int get hashCode => Object.hash(imagePath, blurSigma, darkness);
}
