import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _cacheVersion = 1;
const _versionKey = 'cache_version';

class CacheResult<T> {
  CacheResult(
      {required this.data, required this.cachedAt, required this.fromCache});

  final T data;
  final DateTime? cachedAt;
  final bool fromCache;
}

class PersistentCache {
  PersistentCache({required this.namespace});

  final String namespace;
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrateIfNeeded();
  }

  Future<void> _migrateIfNeeded() async {
    final currentVersion = _prefs?.getInt(_versionKey) ?? 0;
    if (currentVersion < _cacheVersion) {
      await _prefs?.setInt(_versionKey, _cacheVersion);
    }
  }

  String _dataKey(String key) => 'pcache_${namespace}_$key';
  String _timeKey(String key) => 'pcache_${namespace}_${key}_at';

  Future<void> set(String key, dynamic data) async {
    if (_prefs == null) return;
    final jsonStr = jsonEncode(data);
    final now = DateTime.now().toIso8601String();
    await _prefs!.setString(_dataKey(key), jsonStr);
    await _prefs!.setString(_timeKey(key), now);
  }

  CacheResult<T>? get<T>(
      String key, T Function(Map<String, dynamic>) fromJson) {
    if (_prefs == null) return null;
    final jsonStr = _prefs!.getString(_dataKey(key));
    if (jsonStr == null) return null;
    final timeStr = _prefs!.getString(_timeKey(key));
    try {
      final decoded = jsonDecode(jsonStr);
      final data = fromJson(decoded as Map<String, dynamic>);
      final cachedAt = timeStr != null ? DateTime.tryParse(timeStr) : null;
      return CacheResult<T>(data: data, cachedAt: cachedAt, fromCache: true);
    } on Exception {
      return null;
    }
  }

  CacheResult<List<T>>? getList<T>(
      String key, T Function(Map<String, dynamic>) fromJson) {
    if (_prefs == null) return null;
    final jsonStr = _prefs!.getString(_dataKey(key));
    if (jsonStr == null) return null;
    final timeStr = _prefs!.getString(_timeKey(key));
    try {
      final decoded = jsonDecode(jsonStr) as List<dynamic>;
      final items = decoded
          .map((item) => fromJson(item as Map<String, dynamic>))
          .toList();
      final cachedAt = timeStr != null ? DateTime.tryParse(timeStr) : null;
      return CacheResult<List<T>>(
          data: items, cachedAt: cachedAt, fromCache: true);
    } on Exception {
      return null;
    }
  }

  dynamic getRaw(String key) {
    if (_prefs == null) return null;
    final jsonStr = _prefs!.getString(_dataKey(key));
    if (jsonStr == null) return null;
    try {
      return jsonDecode(jsonStr);
    } on Exception {
      return null;
    }
  }

  DateTime? getCachedAt(String key) {
    if (_prefs == null) return null;
    final timeStr = _prefs!.getString(_timeKey(key));
    return timeStr != null ? DateTime.tryParse(timeStr) : null;
  }

  Future<void> remove(String key) async {
    if (_prefs == null) return;
    await _prefs!.remove(_dataKey(key));
    await _prefs!.remove(_timeKey(key));
  }

  Future<void> clearAll() async {
    if (_prefs == null) return;
    final keys = _prefs!.getKeys();
    final prefix = 'pcache_${namespace}_';
    for (final key in keys) {
      if (key.startsWith(prefix)) {
        await _prefs!.remove(key);
      }
    }
  }

  static Future<void> migrateNamespace({
    required String fromNamespace,
    required String toNamespace,
  }) async {
    if (fromNamespace == toNamespace) return;
    final prefs = await SharedPreferences.getInstance();
    final sourcePrefix = 'pcache_${fromNamespace}_';
    final destinationPrefix = 'pcache_${toNamespace}_';
    final sourceKeys = prefs
        .getKeys()
        .where((key) => key.startsWith(sourcePrefix))
        .toList(growable: false);

    for (final sourceKey in sourceKeys) {
      final suffix = sourceKey.substring(sourcePrefix.length);
      final destinationKey = '$destinationPrefix$suffix';
      if (!prefs.containsKey(destinationKey)) {
        final value = prefs.get(sourceKey);
        if (value is String) {
          await prefs.setString(destinationKey, value);
        } else if (value is bool) {
          await prefs.setBool(destinationKey, value);
        } else if (value is int) {
          await prefs.setInt(destinationKey, value);
        } else if (value is double) {
          await prefs.setDouble(destinationKey, value);
        } else if (value is List<String>) {
          await prefs.setStringList(destinationKey, value);
        } else {
          throw StateError('缓存键 $sourceKey 的类型不受支持');
        }
      }
      await prefs.remove(sourceKey);
    }
  }

  static Future<void> clearForStudent(String studentId) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'pcache_${studentId}_';
    final keys = prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith(prefix)) {
        await prefs.remove(key);
      }
    }
  }
}
