import 'dart:convert';

const shiplyPublicContentKey = 'gzus_public_content';
const shiplyPublicContentSchemaVersion = 1;

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

class ShiplyPublicContent {
  const ShiplyPublicContent({
    required this.generatedAt,
    required this.notices,
    required this.loginSlides,
    required this.wechatArticles,
  });

  final String generatedAt;
  final List<ShiplyPublicNotice> notices;
  final List<ShiplyLoginSlide> loginSlides;
  final List<ShiplyWechatArticle> wechatArticles;
}

class ShiplyPublicContentParser {
  const ShiplyPublicContentParser._();

  static ShiplyPublicContent parse({
    required String rootPath,
    required Map<String, String> files,
  }) {
    final manifest = _decodeObject(files, 'manifest.json');
    final schemaVersion =
        _requiredInt(manifest, 'schemaVersion', 'manifest.json');
    if (schemaVersion != shiplyPublicContentSchemaVersion) {
      throw ShiplyPublicContentException(
        'Shiply 公共资源 schemaVersion 不支持: $schemaVersion',
      );
    }
    final resourceKey =
        _requiredString(manifest, 'resourceKey', 'manifest.json');
    if (resourceKey != shiplyPublicContentKey) {
      throw ShiplyPublicContentException(
        'Shiply 公共资源 key 不匹配: $resourceKey',
      );
    }
    final generatedAt =
        _requiredString(manifest, 'generatedAt', 'manifest.json');
    final fileMap = _requiredObject(manifest, 'files', 'manifest.json');
    final noticesFile = _requiredString(fileMap, 'notices', 'manifest.files');
    final slidesFile =
        _requiredString(fileMap, 'loginSlides', 'manifest.files');
    final articlesFile =
        _requiredString(fileMap, 'wechatArticles', 'manifest.files');
    final notices = _parseNotices(_decodeList(files, noticesFile), rootPath);
    final slides = _parseSlides(_decodeList(files, slidesFile), rootPath);
    final articles = _parseArticles(_decodeList(files, articlesFile), rootPath);
    return ShiplyPublicContent(
      generatedAt: generatedAt,
      notices: notices,
      loginSlides: slides,
      wechatArticles: articles,
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

  static Map<String, Object?> _requiredObject(
    Map<String, Object?> value,
    String key,
    String label,
  ) {
    final result = value[key];
    if (result is Map<String, dynamic>) return result.cast<String, Object?>();
    throw ShiplyPublicContentException('$label.$key 必须是 JSON 对象');
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
        localCoverPath: _assetPath(
          item,
          'coverPath',
          rootPath,
          'wechat_articles.json',
        ),
        coverMime: _optionalString(item, 'coverMime', 'wechat_articles.json'),
        source: _requiredString(item, 'source', 'wechat_articles.json'),
      );
    }).toList(growable: false);
  }

  static Map<String, Object?> _decodeObject(
    Map<String, String> files,
    String name,
  ) {
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
      Map<String, Object?> value, String key, String label) {
    final result = value[key];
    if (result is String && result.trim().isNotEmpty) return result;
    throw ShiplyPublicContentException('$label.$key 必须是非空字符串');
  }

  static String? _optionalString(
      Map<String, Object?> value, String key, String label) {
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
      Map<String, Object?> value, String key, String label) {
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
