import 'dart:convert';

const shiplyLoginContentKey = 'gzus_login_content';
const shiplyHomeContentKey = 'gzus_public_content';
const shiplyPublicContentSchemaVersion = 1;
const shiplyLoginResourceKind = 'login';
const shiplyHomeResourceKind = 'home';

class ShiplyPublicContentException implements Exception {
  const ShiplyPublicContentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ShiplyPublicNotice {
  const ShiplyPublicNotice({
    required this.id,
    required this.category,
    required this.title,
    required this.description,
    required this.date,
    required this.url,
    required this.summary,
    required this.localCoverPath,
    required this.source,
    required this.isPinned,
  });

  final int id;
  final String category;
  final String title;
  final String? description;
  final String? date;
  final String? url;
  final String? summary;
  final String? localCoverPath;
  final String source;
  final bool isPinned;
}

class ShiplyLoginSlide {
  const ShiplyLoginSlide({
    required this.id,
    required this.title,
    required this.description,
    required this.localImagePath,
    required this.imageMime,
    required this.sortOrder,
  });

  final int id;
  final String title;
  final String? description;
  final String localImagePath;
  final String imageMime;
  final int sortOrder;
}

class ShiplyWechatArticle {
  const ShiplyWechatArticle({
    required this.id,
    required this.title,
    required this.summary,
    required this.date,
    required this.articleUrl,
    required this.localCoverPath,
    required this.coverMime,
    required this.source,
  });

  final int id;
  final String title;
  final String? summary;
  final String? date;
  final String articleUrl;
  final String? localCoverPath;
  final String? coverMime;
  final String source;
}

class ShiplyLoginContent {
  const ShiplyLoginContent({
    required this.generatedAt,
    required this.loginSlides,
  });

  final String generatedAt;
  final List<ShiplyLoginSlide> loginSlides;
}

class ShiplyHomeContent {
  const ShiplyHomeContent({
    required this.generatedAt,
    required this.notices,
    required this.wechatArticles,
  });

  final String generatedAt;
  final List<ShiplyPublicNotice> notices;
  final List<ShiplyWechatArticle> wechatArticles;
}

class _ShiplyManifest {
  const _ShiplyManifest({required this.generatedAt, required this.files});

  final String generatedAt;
  final Map<String, Object?> files;
}

class ShiplyPublicContentParser {
  const ShiplyPublicContentParser._();

  static ShiplyLoginContent parseLogin({
    required String rootPath,
    required Map<String, String> files,
  }) {
    final manifest = _parseManifest(
      files: files,
      resourceKey: shiplyLoginContentKey,
      resourceKind: shiplyLoginResourceKind,
    );
    final slidesFile = _requiredString(
      manifest.files,
      'loginSlides',
      'manifest.files',
    );
    return ShiplyLoginContent(
      generatedAt: manifest.generatedAt,
      loginSlides: _parseSlides(_decodeList(files, slidesFile), rootPath),
    );
  }

  static ShiplyHomeContent parseHome({
    required String rootPath,
    required Map<String, String> files,
  }) {
    final manifest = _parseManifest(
      files: files,
      resourceKey: shiplyHomeContentKey,
      resourceKind: shiplyHomeResourceKind,
    );
    final noticesFile =
        _requiredString(manifest.files, 'notices', 'manifest.files');
    final articlesFile = _requiredString(
      manifest.files,
      'wechatArticles',
      'manifest.files',
    );
    return ShiplyHomeContent(
      generatedAt: manifest.generatedAt,
      notices: _parseNotices(_decodeList(files, noticesFile), rootPath),
      wechatArticles:
          _parseArticles(_decodeList(files, articlesFile), rootPath),
    );
  }

  static _ShiplyManifest _parseManifest({
    required Map<String, String> files,
    required String resourceKey,
    required String resourceKind,
  }) {
    final manifest = _decodeObject(files, 'manifest.json');
    final schemaVersion =
        _requiredInt(manifest, 'schemaVersion', 'manifest.json');
    if (schemaVersion != shiplyPublicContentSchemaVersion) {
      throw ShiplyPublicContentException(
        'Shiply 公共资源 schemaVersion 不支持: $schemaVersion',
      );
    }
    final actualKey = _requiredString(manifest, 'resourceKey', 'manifest.json');
    if (actualKey != resourceKey) {
      throw ShiplyPublicContentException('Shiply 公共资源 key 不匹配: $actualKey');
    }
    final actualKind =
        _requiredString(manifest, 'resourceKind', 'manifest.json');
    if (actualKind != resourceKind) {
      throw ShiplyPublicContentException('Shiply 公共资源类型不匹配: $actualKind');
    }
    return _ShiplyManifest(
      generatedAt: _requiredString(manifest, 'generatedAt', 'manifest.json'),
      files: _requiredObject(manifest, 'files', 'manifest.json'),
    );
  }

  static List<ShiplyPublicNotice> _parseNotices(
    List<Object?> values,
    String rootPath,
  ) {
    return values.map((value) {
      final item = _asObject(value, 'notices.json item');
      return ShiplyPublicNotice(
        id: _requiredInt(item, 'id', 'notices.json'),
        category: _requiredString(item, 'category', 'notices.json'),
        title: _requiredString(item, 'title', 'notices.json'),
        description: _optionalString(item, 'description', 'notices.json'),
        date: _optionalString(item, 'date', 'notices.json'),
        url: _optionalString(item, 'url', 'notices.json'),
        summary: _optionalString(item, 'summary', 'notices.json'),
        localCoverPath: _assetPath(item, 'coverPath', rootPath, 'notices.json'),
        source: _requiredString(item, 'source', 'notices.json'),
        isPinned: _optionalBool(item, 'isPinned', 'notices.json') ?? false,
      );
    }).toList(growable: false);
  }

  static List<ShiplyLoginSlide> _parseSlides(
    List<Object?> values,
    String rootPath,
  ) {
    return values.map((value) {
      final item = _asObject(value, 'login_slides.json item');
      final relativePath =
          _requiredString(item, 'imagePath', 'login_slides.json');
      return ShiplyLoginSlide(
        id: _requiredInt(item, 'id', 'login_slides.json'),
        title: _requiredString(item, 'title', 'login_slides.json'),
        description: _optionalString(item, 'description', 'login_slides.json'),
        localImagePath:
            _joinAssetPath(rootPath, relativePath, 'login_slides.json'),
        imageMime: _requiredString(item, 'imageMime', 'login_slides.json'),
        sortOrder: _optionalInt(item, 'sortOrder', 'login_slides.json') ?? 0,
      );
    }).toList(growable: false);
  }

  static List<ShiplyWechatArticle> _parseArticles(
    List<Object?> values,
    String rootPath,
  ) {
    return values.map((value) {
      final item = _asObject(value, 'wechat_articles.json item');
      return ShiplyWechatArticle(
        id: _requiredInt(item, 'id', 'wechat_articles.json'),
        title: _requiredString(item, 'title', 'wechat_articles.json'),
        summary: _optionalString(item, 'summary', 'wechat_articles.json'),
        date: _optionalString(item, 'date', 'wechat_articles.json'),
        articleUrl: _requiredString(item, 'articleUrl', 'wechat_articles.json'),
        localCoverPath:
            _assetPath(item, 'coverPath', rootPath, 'wechat_articles.json'),
        coverMime: _optionalString(item, 'coverMime', 'wechat_articles.json'),
        source: _requiredString(item, 'source', 'wechat_articles.json'),
      );
    }).toList(growable: false);
  }

  static Map<String, Object?> _requiredObject(
    Map<String, Object?> value,
    String key,
    String label,
  ) {
    final result = value[key];
    if (result is Map<String, dynamic>) return result.cast<String, Object?>();
    throw ShiplyPublicContentException('$label.$key 必须是 JSON 对象');
  }

  static Map<String, Object?> _decodeObject(
      Map<String, String> files, String name) {
    final value = _decode(files, name);
    if (value is! Map<String, dynamic>) {
      throw ShiplyPublicContentException('$name 必须是 JSON 对象');
    }
    return value.cast<String, Object?>();
  }

  static List<Object?> _decodeList(Map<String, String> files, String name) {
    final value = _decode(files, name);
    if (value is! List<dynamic>) {
      throw ShiplyPublicContentException('$name 必须是 JSON 数组');
    }
    return value.cast<Object?>();
  }

  static Object? _decode(Map<String, String> files, String name) {
    final raw = files[name];
    if (raw == null) {
      throw ShiplyPublicContentException('Shiply 公共资源缺少文件: $name');
    }
    try {
      return jsonDecode(raw);
    } on FormatException catch (error) {
      throw ShiplyPublicContentException('$name JSON 无效: $error');
    }
  }

  static Map<String, Object?> _asObject(Object? value, String label) {
    if (value is Map<String, dynamic>) return value.cast<String, Object?>();
    throw ShiplyPublicContentException('$label 必须是 JSON 对象');
  }

  static String _requiredString(
    Map<String, Object?> value,
    String key,
    String label,
  ) {
    final result = value[key];
    if (result is String && result.trim().isNotEmpty) return result;
    throw ShiplyPublicContentException('$label.$key 必须是非空字符串');
  }

  static String? _optionalString(
    Map<String, Object?> value,
    String key,
    String label,
  ) {
    final result = value[key];
    if (result == null) return null;
    if (result is String) return result;
    throw ShiplyPublicContentException('$label.$key 必须是字符串或 null');
  }

  static int _requiredInt(
      Map<String, Object?> value, String key, String label) {
    final result = value[key];
    if (result is num && result is! double) return result.toInt();
    throw ShiplyPublicContentException('$label.$key 必须是整数');
  }

  static int? _optionalInt(
      Map<String, Object?> value, String key, String label) {
    final result = value[key];
    if (result == null) return null;
    if (result is num && result is! double) return result.toInt();
    throw ShiplyPublicContentException('$label.$key 必须是整数或 null');
  }

  static bool? _optionalBool(
    Map<String, Object?> value,
    String key,
    String label,
  ) {
    final result = value[key];
    if (result == null) return null;
    if (result is bool) return result;
    throw ShiplyPublicContentException('$label.$key 必须是布尔值或 null');
  }

  static String? _assetPath(
    Map<String, Object?> value,
    String key,
    String rootPath,
    String label,
  ) {
    final relativePath = _optionalString(value, key, label);
    if (relativePath == null || relativePath.isEmpty) return null;
    return _joinAssetPath(rootPath, relativePath, label);
  }

  static String _joinAssetPath(
      String rootPath, String relativePath, String label) {
    if (relativePath.startsWith('/') ||
        relativePath.contains('..') ||
        relativePath.contains('\\')) {
      throw ShiplyPublicContentException('$label.$relativePath 不是安全的资源路径');
    }
    return '${rootPath.replaceFirst(RegExp(r'[/\\]+$'), '')}/$relativePath';
  }
}
