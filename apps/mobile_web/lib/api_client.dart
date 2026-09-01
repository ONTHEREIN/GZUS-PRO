import 'dart:convert';
import 'dart:async';
import 'dart:io' show HttpClient, SocketException;

import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:pointycastle/asymmetric/api.dart';

import 'auth_storage.dart';
import 'calendar_import.dart';
import 'leave_attachment.dart';
import 'models/schedule_settings.dart';
import 'models/background_notification_status.dart';
import 'persistent_cache.dart';
import 'schedule_utils.dart';

part 'api_models.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

String _normalizeSingle(String url) {
  final normalized = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  if (defaultTargetPlatform == TargetPlatform.android) {
    final uri = Uri.tryParse(normalized);
    if (uri != null && (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
      return uri.replace(host: '10.0.2.2').toString();
    }
  }
  return normalized;
}

String _defaultApiBaseUrl() {
  // 默认指向腾讯云生产 API；构建时只允许注入一个 API 地址。
  // 可通过 `flutter build --dart-define=API_BASE_URL=...` 覆盖
  const onrein = 'https://onegzus.onrein.top/api';

  return onrein;
}

http.Client _createDefaultClient() {
  if (kIsWeb) {
    return http.Client();
  }
  final ioClient = HttpClient();
  ioClient.userAgent = 'GZUS-PRO/1.0';
  return IOClient(ioClient);
}

bool get _isNativeMobile =>
    !kIsWeb &&
    !debugDisableEcardDirectForTests &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

bool get _isSchoolDirectEnabled =>
    !kIsWeb &&
    !debugDisableSchoolDirectForTests &&
    (debugEnableSchoolDirectForTests ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

@visibleForTesting
bool debugDisableEcardDirectForTests = false;

@visibleForTesting
bool debugDisableSchoolDirectForTests = false;

@visibleForTesting
bool debugEnableSchoolDirectForTests = false;

@visibleForTesting
http.Client? debugSchoolDirectHttpClientForTests;

@visibleForTesting
EcardDirectClient Function()? debugEcardDirectClientFactoryForTests;

EcardDirectClient _createEcardDirectClient() =>
    debugEcardDirectClientFactoryForTests?.call() ?? EcardDirectClient();

class _Fetched<T> {
  const _Fetched({required this.data, required this.source});

  final T data;
  final DataSourceInfo source;
}

class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl, RequestCache? cache})
      : _http = httpClient ?? _createDefaultClient(),
        _cache = cache ?? RequestCache() {
    final raw = baseUrl ?? apiBaseUrl;
    if (raw.contains(',')) {
      throw ArgumentError.value(raw, 'API_BASE_URL', '只支持一个 API 地址');
    }
    final configured = raw.trim();
    this.baseUrl = _normalizeSingle(
      configured.isEmpty ? _defaultApiBaseUrl() : configured,
    );
  }

  final http.Client _http;
  static const AuthStorage _authStorage = AuthStorage();
  late final String baseUrl;
  final RequestCache _cache;
  final Map<String, Future<void>> _backgroundRefreshes = {};
  final Map<String, DateTime> _backgroundRefreshAt = {};
  String? sessionId;
  String? _studentId;
  String? _offlineScheduleStudentId;
  String? _account;
  PersistentCache? _persistentCache;
  Future<PersistentCache>? _persistentCacheFuture;
  String? _credentialToken;
  String? _jwxtCookies;
  String? _ehallCookies;
  String? _ehallAuthToken;
  String? _rsaPublicKeyPem;
  String? _rsaKeyId;
  Future<void>? _publicKeyFuture;

  /// 当自动重新登录失败时调用的回调，UI 层可用来导航到登录页
  void Function()? onReloginFailed;

  /// 静默重登生成新会话后调用，供推送和 WebSocket 重新绑定会话。
  Future<void> Function(String sessionId)? onSessionReplaced;

  /// --- Relogin backoff state ---
  /// Tracks the last time a relogin attempt was made and how many
  /// consecutive failures occurred.  Prevents hammering the CAS server
  /// when relogin keeps failing.
  DateTime? _lastReloginAttempt;
  int _consecutiveReloginFailures = 0;
  Future<LoginResult>? _reloginFuture;

  /// Minimum interval between relogin attempts (increases with failures).
  static const Duration _reloginMinInterval = Duration(seconds: 5);
  static const int _reloginMaxBackoffSeconds = 120;

  static const Duration _backgroundRefreshCooldown = Duration(minutes: 5);

  String get namespace =>
      _studentId ?? _offlineScheduleStudentId ?? sessionId ?? 'default';
  String? get studentId => _studentId;
  bool get isScheduleOnlyMode => _offlineScheduleStudentId != null;
  String? get jwxtCookies => _jwxtCookies;
  String? get ehallCookies => _ehallCookies;
  String? get ehallAuthToken => _ehallAuthToken;

  void setJwxtCookies(String? value) {
    _jwxtCookies = value;
  }

  void setEhallCookies(String? value) {
    _ehallCookies = value;
  }

  void setEhallAuthToken(String? value) {
    _ehallAuthToken = value;
  }

  void useSession(String? value) {
    if (sessionId != value) _cache.clear();
    sessionId = value;
  }

  void setStudentId(String? value) {
    if (_studentId != value) {
      _studentId = value;
      _persistentCache = null;
      _persistentCacheFuture = null;
    }
    if (value != null) _offlineScheduleStudentId = null;
  }

  Future<void> adoptStudentIdentity({
    required String studentId,
    required String sessionNamespace,
  }) async {
    if (studentId.isEmpty) {
      throw ArgumentError.value(studentId, 'studentId', '学号不能为空');
    }
    await PersistentCache.migrateNamespace(
      fromNamespace: sessionNamespace,
      toNamespace: studentId,
    );
    setStudentId(studentId);
  }

  Future<PersistentCache> _getPersistentCache() async {
    final cache = _persistentCache;
    if (cache != null) return cache;

    final initializing = _persistentCacheFuture;
    if (initializing != null) return initializing;

    final cacheNamespace = namespace;
    final future = () async {
      final cache = PersistentCache(namespace: cacheNamespace);
      await cache.init();
      if (cacheNamespace == namespace) {
        _persistentCache = cache;
      }
      return cache;
    }();
    _persistentCacheFuture = future;
    try {
      return await future;
    } finally {
      if (_persistentCacheFuture == future) {
        _persistentCacheFuture = null;
      }
    }
  }

  DataSourceInfo _localSource(DateTime? cachedAt) => DataSourceInfo(
        fromLocalCache: true,
        cachedAt: cachedAt,
      );

  DataSourceInfo _offlineSource(DateTime? cachedAt, ApiException error) =>
      DataSourceInfo(
        fromLocalCache: true,
        cachedAt: cachedAt,
        isOffline: true,
        needsRelogin: error.statusCode == 401,
      );

  Map<String, dynamic>? _cachedObject(PersistentCache cache, String key) {
    final cached = cache.getRaw(key);
    return cached is Map<String, dynamic> ? cached : null;
  }

  List<Map<String, dynamic>>? _cachedList(PersistentCache cache, String key) {
    final cached = cache.getRaw(key);
    if (cached is! List<dynamic>) return null;
    final result = <Map<String, dynamic>>[];
    for (final item in cached) {
      if (item is! Map<String, dynamic>) return null;
      result.add(item);
    }
    return result;
  }

  void _queueBackgroundRefresh(
    String cacheKey,
    Future<void> Function() refresh,
  ) {
    if (_backgroundRefreshes.containsKey(cacheKey)) return;
    final lastRefresh = _backgroundRefreshAt[cacheKey];
    if (lastRefresh != null &&
        DateTime.now().difference(lastRefresh) < _backgroundRefreshCooldown) {
      return;
    }
    _backgroundRefreshAt[cacheKey] = DateTime.now();
    late final Future<void> refreshFuture;
    refreshFuture = refresh().catchError((_) {}).whenComplete(() {
      if (_backgroundRefreshes[cacheKey] == refreshFuture) {
        _backgroundRefreshes.remove(cacheKey);
      }
    });
    _backgroundRefreshes[cacheKey] = refreshFuture;
  }

  Future<DataResult<T>> _cacheFirstObject<T>({
    required String cacheKey,
    required Future<_Fetched<Map<String, dynamic>>> Function() fetch,
    required T Function(Map<String, dynamic>) fromJson,
    bool forceRefresh = false,
    Duration? memoryTtl,
  }) async {
    if (!forceRefresh) {
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(data: fromJson(memCached));
      }
    }

    final pcache = await _getPersistentCache();

    Future<DataResult<T>> fetchAndCache() async {
      final fetched = await fetch();
      final data = fetched.data;
      _cache.set(cacheKey, data, memoryTtl);
      await pcache.set(cacheKey, data);
      return DataResult<T>(data: fromJson(data), source: fetched.source);
    }

    if (!forceRefresh) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        _cache.set(cacheKey, cached, memoryTtl);
        _queueBackgroundRefresh(cacheKey, () async {
          await fetchAndCache();
        });
        return DataResult<T>(
          data: fromJson(cached),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
    }

    try {
      return await fetchAndCache();
    } on ApiException catch (e) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        return DataResult<T>(
          data: fromJson(cached),
          source: _offlineSource(pcache.getCachedAt(cacheKey), e),
        );
      }
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(
          data: fromJson(memCached),
          source: DataSourceInfo(
            fromCache: true,
            needsRelogin: e.statusCode == 401,
          ),
        );
      }
      rethrow;
    } catch (e) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        return DataResult<T>(
          data: fromJson(cached),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(
          data: fromJson(memCached),
          source: const DataSourceInfo(fromCache: true),
        );
      }
      rethrow;
    }
  }

  Future<DataResult<List<T>>> _cacheFirstList<T>({
    required String cacheKey,
    required Future<_Fetched<List<Map<String, dynamic>>>> Function() fetch,
    required T Function(Map<String, dynamic>) fromJson,
    bool forceRefresh = false,
    Duration? memoryTtl,
  }) async {
    if (!forceRefresh) {
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
        );
      }
    }

    final pcache = await _getPersistentCache();

    Future<DataResult<List<T>>> fetchAndCache() async {
      final fetched = await fetch();
      final data = fetched.data;
      _cache.set(cacheKey, data, memoryTtl);
      await pcache.set(cacheKey, data);
      return DataResult<List<T>>(
        data: data.map((item) => fromJson(item)).toList(),
        source: fetched.source,
      );
    }

    if (!forceRefresh) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        _cache.set(cacheKey, cached, memoryTtl);
        _queueBackgroundRefresh(cacheKey, () async {
          await fetchAndCache();
        });
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
    }

    try {
      return await fetchAndCache();
    } on ApiException catch (e) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _offlineSource(pcache.getCachedAt(cacheKey), e),
        );
      }
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
          source: DataSourceInfo(
            fromCache: true,
            needsRelogin: e.statusCode == 401,
          ),
        );
      }
      rethrow;
    } catch (e) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
          source: const DataSourceInfo(fromCache: true),
        );
      }
      rethrow;
    }
  }

  String lySsoStartUrl({required String returnUrl}) {
    final url = _requireBaseUrl();
    final uri = Uri.parse('$url/auth/ly/start');
    return uri.replace(queryParameters: {'return_url': returnUrl}).toString();
  }

  Future<LoginResult> completeLySso(String ssoCode) async {
    final response =
        await _postWithoutRelogin('/auth/ly/complete', {'ssoCode': ssoCode});
    return _applySsoLoginResponse(response);
  }

  Future<String> startNativeLySso(String verifier) async {
    final response = await _postWithoutRelogin(
        '/auth/ly/native-start', {'verifier': verifier});
    final authorizationUrl = response['authorizationUrl'];
    if (authorizationUrl is! String || authorizationUrl.isEmpty) {
      throw ApiException('服务器未返回统一身份认证地址');
    }
    return authorizationUrl;
  }

  Future<LoginResult> completeNativeLySso(String code, String verifier) async {
    final response = await _postWithoutRelogin(
      '/auth/ly/native-complete',
      {'code': code, 'verifier': verifier},
    );
    return _applySsoLoginResponse(response);
  }

  Future<LoginResult> _applySsoLoginResponse(
      Map<String, dynamic> response) async {
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    await _adoptLoginIdentity(result);
    _captureTransientEhallAuth(result);
    _cache.clear();
    await _saveSchoolAuth(result);
    return result;
  }

  Future<LoginResult> autoLogin(String account, String password) async {
    _account = account;
    final response = await _postLoginWithFreshKeyRetry(
      '/auth/auto-login',
      account,
      password,
    );
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    await _adoptLoginIdentity(result);
    _captureTransientEhallAuth(result);
    _cache.clear();
    if (result.credentialToken != null) {
      _credentialToken = result.credentialToken;
    }
    await _saveSchoolAuth(result);
    return result;
  }

  Future<Map<String, dynamic>> _postLoginWithFreshKeyRetry(
    String path,
    String account,
    String password,
  ) async {
    await fetchPublicKey();
    try {
      return await _postWithoutRelogin(path, _loginPayload(account, password));
    } on ApiException catch (e) {
      if (!_isPasswordDecryptFailure(e.message)) rethrow;
      await _refreshPublicKey();
      return _postWithoutRelogin(path, _loginPayload(account, password));
    }
  }

  Map<String, dynamic> _loginPayload(String account, String password) {
    final body = <String, dynamic>{'account': account};
    final publicKeyPem = _rsaPublicKeyPem;
    final keyId = _rsaKeyId;
    if (publicKeyPem != null && keyId != null) {
      final encrypted = _rsaEncrypt(password, publicKeyPem);
      if (encrypted != null) {
        body['encryptedPassword'] = encrypted;
        body['keyId'] = keyId;
        return body;
      }
    }
    body['password'] = password;
    return body;
  }

  bool _isPasswordDecryptFailure(String message) =>
      message.contains('密码解密失败') || message.contains('RSA密钥不匹配');

  Future<bool> checkHealth() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/health'), headers: _headers())
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } on SocketException {
      return false;
    }
  }

  Future<void> revokeSession(String activeSessionId) async {
    await _postSessionCleanup('/auth/logout', activeSessionId);
  }

  /// 立即清除凭证，防止后续请求触发 relogin 重试
  void clearCredentials() {
    sessionId = null;
    _account = null;
    setStudentId(null);
    _offlineScheduleStudentId = null;
    _credentialToken = null;
    _jwxtCookies = null;
    _ehallCookies = null;
    _ehallAuthToken = null;
    _cache.clear();
  }

  Future<void> clearSavedAuthState() async {
    clearCredentials();
    await _authStorage.clear();
    await _clearSavedAuthPreferences();
  }

  /// 登录态失效后清除个人数据，只允许读取此前缓存的课表。
  Future<void> enterScheduleOnlyMode() async {
    if (_offlineScheduleStudentId != null) return;
    final expiredStudentId = _studentId;
    _clearAuthenticationForReverification();
    await _authStorage.clear();
    await _clearSavedSessionPreferencesForReverification();
    if (expiredStudentId == null || expiredStudentId.isEmpty) return;
    _offlineScheduleStudentId = expiredStudentId;
    await PersistentCache.clearForStudentExceptSchedule(expiredStudentId);
  }

  Future<void> _clearSavedAuthPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth.sessionId');
    await prefs.remove('auth.studentName');
    await prefs.remove('auth.studentId');
    await prefs.remove('auth.loginMethod');
    await prefs.remove('auth.account');
    await prefs.remove('auth.password');
    await prefs.remove('auth.rememberPassword');
  }

  void _clearAuthenticationForReverification() {
    sessionId = null;
    setStudentId(null);
    _offlineScheduleStudentId = null;
    _credentialToken = null;
    _jwxtCookies = null;
    _ehallCookies = null;
    _ehallAuthToken = null;
    _cache.clear();
  }

  Future<void> _clearSavedSessionPreferencesForReverification() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth.sessionId');
    await prefs.remove('auth.studentName');
    await prefs.remove('auth.studentId');
    await prefs.remove('auth.loginMethod');
    await prefs.remove('auth.password');
  }

  Future<LoginResult> relogin() async {
    final inFlight = _reloginFuture;
    if (inFlight != null) return inFlight;
    final future = _reloginOnce();
    _reloginFuture = future;
    try {
      return await future;
    } finally {
      if (_reloginFuture == future) _reloginFuture = null;
    }
  }

  Future<LoginResult> _reloginOnce() async {
    await loadSavedCredentials();
    if (_credentialToken != null) {
      return _reloginWithCredentialToken(_credentialToken!);
    }
    throw ApiException('登录状态已失效，请重新登录', statusCode: 401);
  }

  Future<LoginResult> _reloginWithCredentialToken(
      String credentialToken) async {
    // 直接发HTTP请求，不走 _withReloginRetry，避免 relogin 自身 401 时无限递归
    final url = _requireBaseUrl();
    final response = await _http
        .post(Uri.parse('$url/auth/relogin'),
            headers: _headers(),
            body: jsonEncode({'credentialToken': credentialToken}))
        .timeout(_requestTimeout);
    final decoded = _decode(response);
    final result = LoginResult.fromJson(decoded as Map<String, dynamic>);
    final previousSessionId = sessionId;
    sessionId = result.sessionId;
    await _adoptLoginIdentity(result);
    _captureTransientEhallAuth(result);
    _cache.clear();

    await saveCredentialToken(result.credentialToken ?? credentialToken);
    await _saveSchoolAuth(result);
    final activeSessionId = result.sessionId;
    if (activeSessionId != null && activeSessionId != previousSessionId) {
      await onSessionReplaced?.call(activeSessionId);
    }
    return result;
  }

  Future<void> _adoptLoginIdentity(LoginResult result) async {
    final studentId = result.studentId;
    final currentSessionId = sessionId;
    if (studentId == null || studentId.isEmpty || currentSessionId == null) {
      return;
    }
    await adoptStudentIdentity(
      studentId: studentId,
      sessionNamespace: currentSessionId,
    );
  }

  Future<void> saveCredentialToken(String? credentialToken) async {
    if (credentialToken == null || credentialToken.isEmpty) return;
    await _authStorage.saveCredentialToken(credentialToken);
    _credentialToken = credentialToken;
  }

  Future<void> clearSavedCredentialToken() async {
    _credentialToken = null;
    await _authStorage.clearCredentialToken();
  }

  Future<void> rememberAccount(String account) async {
    _account = account;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth.rememberPassword', true);
    await prefs.remove('auth.password');
    await prefs.setString('auth.account', account);
  }

  Future<void> forgetRememberedAccount() async {
    _account = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth.rememberPassword', false);
    await prefs.remove('auth.account');
    await prefs.remove('auth.password');
  }

  Future<void> _saveSchoolAuth(LoginResult result) async {
    final prefs = await SharedPreferences.getInstance();
    if (result.sessionId != null && result.sessionId!.isNotEmpty) {
      await prefs.setString('auth.sessionId', result.sessionId!);
    }
    await _authStorage.saveSchoolAuth(
      result.jwxtCookies,
      result.ehallCookies,
      result.ehallAuthToken,
    );
  }

  Future<void> loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final sensitiveAuth = await _authStorage.load();
    _account = prefs.getString('auth.account');
    _credentialToken = sensitiveAuth.credentialToken;
    if (_isSchoolDirectEnabled) {
      _jwxtCookies = sensitiveAuth.jwxtCookies;
    }
    _ehallCookies = sensitiveAuth.ehallCookies;
    _ehallAuthToken = sensitiveAuth.ehallAuthToken;
    await prefs.remove('auth.password');
  }

  Future<void> fetchPublicKey() async {
    if (_rsaPublicKeyPem != null && _rsaKeyId != null) return;
    final current = _publicKeyFuture;
    if (current != null) return current;
    final future = _fetchPublicKeyOnce();
    _publicKeyFuture = future;
    try {
      await future;
    } finally {
      if (_publicKeyFuture == future) {
        _publicKeyFuture = null;
      }
    }
  }

  Future<void> _refreshPublicKey() async {
    _rsaPublicKeyPem = null;
    _rsaKeyId = null;
    await _fetchPublicKeyOnce();
  }

  Future<void> _fetchPublicKeyOnce() async {
    try {
      final url = _requireBaseUrl();
      final response = await _http.get(Uri.parse('$url/auth/public-key'),
          headers: {
            'Content-Type': 'application/json'
          }).timeout(const Duration(seconds: 3));
      final data = _decodeObject(response);
      final pem = data['publicKey'] as String? ?? '';
      final keyId = data['keyId'] as String? ?? '';
      if (pem.isNotEmpty && keyId.isNotEmpty) {
        if (_rsaKeyId != null && _rsaKeyId != keyId) {
          // Key rotated - update cached key
          _rsaPublicKeyPem = pem;
          _rsaKeyId = keyId;
        } else if (_rsaPublicKeyPem == null) {
          _rsaPublicKeyPem = pem;
          _rsaKeyId = keyId;
        }
      }
    } catch (_) {
      // If public key fetch fails, we'll fall back to plaintext password
    }
  }

  String? _rsaEncrypt(String plaintext, String publicKeyPem) {
    try {
      final parser = encrypt.RSAKeyParser();
      final publicKey = parser.parse(publicKeyPem) as RSAPublicKey;
      final encrypter = encrypt.Encrypter(encrypt.RSA(
        publicKey: publicKey,
        encoding: encrypt.RSAEncoding.PKCS1,
      ));
      final encrypted = encrypter.encrypt(plaintext);
      return encrypted.base64;
    } catch (_) {
      return null;
    }
  }

  void _captureTransientEhallAuth(LoginResult result) {
    if (_isSchoolDirectEnabled &&
        result.jwxtCookies != null &&
        result.jwxtCookies!.isNotEmpty) {
      _jwxtCookies = result.jwxtCookies;
    }
    _ehallCookies = result.ehallCookies;
    _ehallAuthToken = result.ehallAuthToken;
  }

  Future<DataResult<StudentInfo>> me({bool forceRefresh = false}) =>
      _cacheFirstObject<StudentInfo>(
        cacheKey: 'me',
        fetch: () =>
            _plainObject(_get('/me${forceRefresh ? '?refresh=true' : ''}')),
        fromJson: (json) => StudentInfo.fromJson(json),
        forceRefresh: forceRefresh,
      );

  StudentInfo? cachedStudentInfo() {
    final cached = _cache.get<Map<String, dynamic>>('me');
    return cached == null ? null : StudentInfo.fromJson(cached);
  }

  /// 登录后异步获取个人信息。
  ///
  /// 复用 /me，让首次请求写入服务器缓存，之后打开信息页可直接命中；
  /// 请求仍不走自动重登，避免登录后的短暂网络抖动触发登出。
  Future<StudentInfo?> fetchStudentInfo() async {
    try {
      // Use a direct HTTP call without _withReloginRetry to avoid
      // triggering onReloginFailed->_logout() when called immediately
      // 登录后短暂网络抖动可能导致瞬态 401。
      final url = _requireBaseUrl();
      if (url.isEmpty) return null;
      final response = await _http
          .get(Uri.parse('$url/me'), headers: _headers())
          .timeout(_connectTimeout)
          .timeout(_requestTimeout);
      if (response.statusCode >= 400) {
        // Silently ignore errors — this is a best-effort fetch after login.
        return null;
      }
      final data = _decodeObject(response);
      final info = StudentInfo.fromJson(data);
      final studentId = info.studentId;
      if (studentId.isNotEmpty) {
        final currentSessionId = sessionId;
        if (currentSessionId != null) {
          await adoptStudentIdentity(
            studentId: studentId,
            sessionNamespace: currentSessionId,
          );
        } else {
          setStudentId(studentId);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth.studentId', studentId);
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  /// 拉取云端课表偏好（开学日期等，按学号绑定）。
  /// 登录/会话恢复后 best-effort 调用：直接 HTTP 请求、失败返回 null，
  /// 不触发 _withReloginRetry 的自动重登流程（与 fetchStudentInfo 同理，
  /// 避免登录后瞬时 401 误触发 onReloginFailed）。
  Future<ScheduleSettings?> fetchScheduleSettings() async {
    try {
      final url = _requireBaseUrl();
      final response = await _http
          .get(Uri.parse('$url/settings/schedule'), headers: _headers())
          .timeout(_connectTimeout)
          .timeout(_requestTimeout);
      if (response.statusCode >= 400) return null;
      return ScheduleSettings.fromJson(_decodeObject(response));
    } catch (_) {
      return null;
    }
  }

  /// 保存云端课表偏好。
  /// [firstWeeks] 为按学期合并（服务端保留其他学期），
  /// [onboardingCompleted] 标记开学引导已完成。
  Future<void> saveScheduleSettings({
    Map<String, String>? firstWeeks,
    bool? autoWeek,
    bool? onboardingCompleted,
  }) async {
    await _put('/settings/schedule', {
      if (firstWeeks != null) 'firstWeeks': firstWeeks,
      if (autoWeek != null) 'autoWeek': autoWeek,
      if (onboardingCompleted != null)
        'onboardingCompleted': onboardingCompleted,
    });
  }

  Future<BackgroundNotificationStatus?>
      fetchBackgroundNotificationStatus() async {
    try {
      final url = _requireBaseUrl();
      final response = await _http
          .get(Uri.parse('$url/notifications/background'), headers: _headers())
          .timeout(_requestTimeout);
      if (response.statusCode >= 400) return null;
      return BackgroundNotificationStatus.fromJson(_decodeObject(response));
    } catch (_) {
      return null;
    }
  }

  Future<BackgroundNotificationStatus> setBackgroundNotificationAccess(
    bool enabled,
  ) async {
    await loadSavedCredentials();
    if (enabled && (_credentialToken == null || _credentialToken!.isEmpty)) {
      throw StateError('请使用账号密码登录并勾选记住账号后，再开启后台持续通知');
    }
    final data = await _put('/notifications/background', {
      'enabled': enabled,
      if (enabled) 'credentialToken': _credentialToken,
    });
    return BackgroundNotificationStatus.fromJson(data);
  }

  Future<void> syncCloudCourseReminders({
    required bool enabled,
    required int beforeStartMinutes,
    required int beforeEndMinutes,
    required DateTime firstWeekStart,
    required List<Map<String, dynamic>> courses,
  }) async {
    await _put('/notifications/course-reminders', {
      'enabled': enabled,
      'beforeStartMinutes': beforeStartMinutes,
      'beforeEndMinutes': beforeEndMinutes,
      'firstWeekStart':
          '${firstWeekStart.year.toString().padLeft(4, '0')}-${firstWeekStart.month.toString().padLeft(2, '0')}-${firstWeekStart.day.toString().padLeft(2, '0')}',
      'courses': courses,
    });
  }

  Future<void> revokeBackgroundNotificationAccess(
      String activeSessionId) async {
    final url = _requireBaseUrl();
    final response = await _http
        .put(
          Uri.parse('$url/notifications/background'),
          headers: {..._headers(), 'X-Session-Id': activeSessionId},
          body: jsonEncode({'enabled': false}),
        )
        .timeout(_requestTimeout);
    if (response.statusCode >= 400) {
      final detail = _decode(response);
      throw ApiException('撤销后台通知授权失败：$detail', statusCode: response.statusCode);
    }
  }

  SchoolDirectClient? _schoolDirectClient() {
    final cookies = _jwxtCookies;
    if (!_isSchoolDirectEnabled || cookies == null || cookies.isEmpty) {
      return null;
    }
    return SchoolDirectClient(
      cookies: cookies,
      account: _account ?? _studentId,
      httpClient: debugSchoolDirectHttpClientForTests ?? _http,
    );
  }

  Future<List<Map<String, dynamic>>> _schoolDirectListOrApi({
    required String path,
    required Future<List<Map<String, dynamic>>> Function(SchoolDirectClient)
        direct,
  }) async {
    try {
      return await _getList(path);
    } catch (error, stackTrace) {
      if (!_isApiUnavailable(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final client = _schoolDirectClient();
      if (client == null) Error.throwWithStackTrace(error, stackTrace);
      try {
        final data = await direct(client);
        return data;
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  Future<_Fetched<List<Map<String, dynamic>>>> _academicListOrDirect({
    required String path,
    required Future<List<Map<String, dynamic>>> Function(SchoolDirectClient)
        direct,
  }) async {
    try {
      return await _getListWithSource(path);
    } catch (error, stackTrace) {
      if (!_isApiUnavailable(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final client = _schoolDirectClient();
      if (client == null) Error.throwWithStackTrace(error, stackTrace);
      try {
        return _Fetched(
          data: await direct(client),
          source: const DataSourceInfo(),
        );
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  Future<_Fetched<Map<String, dynamic>>> _academicObjectOrDirect({
    required String path,
    required Future<Map<String, dynamic>> Function(SchoolDirectClient) direct,
  }) async {
    try {
      return await _getObjectWithSource(path);
    } catch (error, stackTrace) {
      if (!_isApiUnavailable(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final client = _schoolDirectClient();
      if (client == null) Error.throwWithStackTrace(error, stackTrace);
      try {
        return _Fetched(
          data: await direct(client),
          source: const DataSourceInfo(),
        );
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  bool _isApiUnavailable(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException ||
      (error is ApiException &&
          error.statusCode != null &&
          error.statusCode! >= 500);

  Future<_Fetched<Map<String, dynamic>>> _plainObject(
    Future<Map<String, dynamic>> request,
  ) async =>
      _Fetched(data: await request, source: const DataSourceInfo());

  Future<_Fetched<List<Map<String, dynamic>>>> _plainList(
    Future<List<Map<String, dynamic>>> request,
  ) async =>
      _Fetched(data: await request, source: const DataSourceInfo());

  Future<DataResult<ScheduleResult>> schedule(
      {required int year, required int term, bool forceRefresh = false}) async {
    final cacheKey = 'schedule_${year}_$term';
    return _cacheFirstList<ScheduleCourse>(
      cacheKey: cacheKey,
      fetch: () => _plainList(_schoolDirectListOrApi(
        path:
            '/schedule?year=$year&term=$term${forceRefresh ? '&refresh=true' : ''}',
        direct: (client) => client.schedule(year: year, term: term),
      )),
      fromJson: (json) => ScheduleCourse.fromJson(json),
      forceRefresh: forceRefresh,
    ).then(
      (result) => DataResult<ScheduleResult>(
        data: ScheduleResult(
          raw: result.data.map((item) => item.raw).toList(),
          items: result.data,
        ),
        source: result.source,
      ),
    );
  }

  Future<DataResult<List<ExamItem>>> exams(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstList<ExamItem>(
        cacheKey: 'exams_${year}_$term',
        fetch: () => _academicListOrDirect(
          path:
              '/exams?year=$year&term=$term${forceRefresh ? '&refresh=true' : ''}',
          direct: (client) => client.exams(year: year, term: term),
        ),
        fromJson: (json) => ExamItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<List<GradeItem>>> grades(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstList<GradeItem>(
        cacheKey: 'grades_${year}_$term',
        fetch: () => _plainList(_schoolDirectListOrApi(
          path:
              '/grades?year=$year&term=$term${forceRefresh ? '&refresh=true' : ''}',
          direct: (client) => client.grades(year: year, term: term),
        )),
        fromJson: (json) => GradeItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<AttendanceResponse>> attendance(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstObject<AttendanceResponse>(
        // 明细查询依赖 courseId；旧版缓存未包含该字段，必须跳过。
        cacheKey: _attendanceCacheKey(year: year, term: term),
        fetch: () => _academicObjectOrDirect(
          path:
              '/attendance?year=$year&term=$term${forceRefresh ? '&refresh=true' : ''}',
          direct: (client) => client.attendance(year: year, term: term),
        ),
        fromJson: (json) => AttendanceResponse.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<AttendanceDetailResponse>> attendanceDetails({
    required int year,
    required int term,
    required String courseId,
    bool forceRefresh = false,
  }) =>
      _cacheFirstObject<AttendanceDetailResponse>(
        cacheKey: 'attendance_detail_$year' '_$term' '_$courseId',
        fetch: () => _plainObject(
          _get(
            '/attendance/details?year=$year&term=$term&courseId=${Uri.encodeComponent(courseId)}${forceRefresh ? '&refresh=true' : ''}',
          ),
        ),
        fromJson: (json) => AttendanceDetailResponse.fromJson(json),
        forceRefresh: forceRefresh,
      );

  String _attendanceCacheKey({required int year, required int term}) =>
      'attendance_v2_${year}_$term';

  /// 返回 dashboard 已写入内存的考勤快照，供详情页首屏直接复用。
  AttendanceResponse? cachedAttendance({required int year, required int term}) {
    final cached = _cache.get<Map<String, dynamic>>(
      _attendanceCacheKey(year: year, term: term),
    );
    return cached == null ? null : AttendanceResponse.fromJson(cached);
  }

  ScheduleResult? cachedSchedule({required int year, required int term}) {
    final cached = _cache.get<List<dynamic>>('schedule_${year}_$term');
    if (cached == null) return null;
    final items = cached
        .whereType<Map<String, dynamic>>()
        .map(ScheduleCourse.fromJson)
        .toList();
    return ScheduleResult(
      items: items,
      raw: items.map((item) => item.raw).toList(),
    );
  }

  List<CreditItem>? cachedCredits() {
    final cached = _cache.get<List<dynamic>>('credits');
    return cached
        ?.whereType<Map<String, dynamic>>()
        .map(CreditItem.fromJson)
        .toList();
  }

  Future<DataResult<List<CreditItem>>> credits({bool forceRefresh = false}) =>
      _cacheFirstList<CreditItem>(
        cacheKey: 'credits',
        fetch: () => _plainList(_schoolDirectListOrApi(
          path: '/credits${forceRefresh ? '?refresh=true' : ''}',
          direct: (client) => client.credits(),
        )),
        fromJson: (json) => CreditItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<WeatherData>> weather({
    bool forceRefresh = false,
    double? lat,
    double? lon,
  }) =>
      _cacheFirstObject<WeatherData>(
        cacheKey: _weatherCacheKey(lat, lon),
        fetch: () => _plainObject(_getDirectWeather(lat, lon)),
        fromJson: (json) => WeatherData.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 30),
      );

  Future<Map<String, dynamic>> _getDirectWeather(
      double? lat, double? lon) async {
    final location = lat != null && lon != null
        ? '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}'
        : 'Guangzhou';
    final response = await _http
        .get(
          Uri.https('wttr.in', '/$location', {'format': 'j1'}),
          headers: {'Accept': 'application/json', 'User-Agent': 'OneGZUS/1.0'},
        )
        .timeout(_connectTimeout)
        .timeout(_requestTimeout);
    return _normalizeWttrWeather(_decodeObject(response));
  }

  Map<String, dynamic> _normalizeWttrWeather(Map<String, dynamic> raw) {
    final current = _firstWeatherMap(raw['current_condition']);
    final nearest = _firstWeatherMap(raw['nearest_area']);
    final days = raw['weather'] is List<dynamic>
        ? (raw['weather'] as List<dynamic>).whereType<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    final code = '${current['weatherCode'] ?? '116'}';
    final forecasts = <Map<String, dynamic>>[];
    for (final day in days) {
      final hourly = day['hourly'] is List<dynamic>
          ? (day['hourly'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .toList()
          : const <Map<String, dynamic>>[];
      if (hourly.isEmpty) continue;
      final mid = hourly[hourly.length ~/ 2];
      final date = '${day['date'] ?? ''}';
      forecasts.add({
        'date': date,
        'week': _weatherWeekday(date),
        'temp_max': _weatherDouble(day['maxtempC']),
        'temp_min': _weatherDouble(day['mintempC']),
        'weather_day': _weatherDescription('${mid['weatherCode'] ?? '116'}'),
      });
    }
    final area = _firstWeatherValue(nearest['areaName']);
    final region = _firstWeatherValue(nearest['region']);
    return {
      'province': region.isEmpty ? '广东' : region,
      'city': area.isEmpty ? '广州' : area,
      'district': area.isEmpty ? '广州' : area,
      'weather': _weatherDescription(code),
      'weather_icon': code,
      'temperature': _weatherDouble(current['temp_C']),
      'wind_direction': '${current['winddir16Point'] ?? ''}',
      'wind_power': _weatherWindPower(_weatherDouble(current['windspeedKmph'])),
      'humidity': _weatherInt(current['humidity']),
      'temp_max': days.isEmpty ? null : _weatherDouble(days.first['maxtempC']),
      'temp_min': days.isEmpty ? null : _weatherDouble(days.first['mintempC']),
      'forecast': forecasts,
    };
  }

  Map<String, dynamic> _firstWeatherMap(dynamic value) {
    if (value is List<dynamic> && value.isNotEmpty) {
      final first = value.first;
      if (first is Map<String, dynamic>) return first;
    }
    return const <String, dynamic>{};
  }

  String _firstWeatherValue(dynamic value) {
    final first = _firstWeatherMap(value);
    return '${first['value'] ?? ''}';
  }

  double _weatherDouble(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  int _weatherInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  String _weatherDescription(String code) =>
      const {
        '113': '晴',
        '116': '多云',
        '119': '阴',
        '122': '阴',
        '143': '雾',
        '176': '小雨',
        '200': '雷阵雨',
        '299': '中雨',
        '305': '大雨',
        '308': '暴雨',
        '323': '中雪',
        '329': '大雪',
        '386': '雷阵雨',
      }[code] ??
      '多云';

  String _weatherWindPower(double speed) {
    if (speed < 6) return '1级';
    if (speed < 12) return '2级';
    if (speed < 20) return '3级';
    if (speed < 29) return '4级';
    if (speed < 39) return '5级';
    if (speed < 50) return '6级';
    if (speed < 62) return '7级';
    return '8级+';
  }

  String _weatherWeekday(String date) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return '';
    return const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][parsed.weekday - 1];
  }

  Future<DataResult<DashboardSnapshot>> dashboard({
    required int year,
    required int term,
    required int week,
    bool forceRefresh = false,
  }) async {
    final result = await _cacheFirstObject<DashboardSnapshot>(
      cacheKey: 'dashboard_${year}_${term}_$week',
      fetch: () => _plainObject(_getDashboardObject(
        '/dashboard?year=$year&term=$term&week=$week${forceRefresh ? '&refresh=true' : ''}',
      )),
      fromJson: (json) => DashboardSnapshot.fromJson(json),
      forceRefresh: forceRefresh,
      memoryTtl: const Duration(minutes: 2),
    );
    _seedModuleCachesFromDashboard(result.data, year, term);
    return result;
  }

  /// 将 dashboard 各模块数据写入与独立端点相同的内存缓存 key，
  /// 使详情页首次进入直接命中缓存，省掉一次重复的网络往返。
  void _seedModuleCachesFromDashboard(
    DashboardSnapshot snapshot,
    int year,
    int term,
  ) {
    void seedList(String module, String cacheKey) {
      final mod = snapshot.module(module);
      if (!mod.hasUsableData) return;
      final items = mod.listData();
      _cache.set(cacheKey, items);
    }

    void seedObject(String module, String cacheKey) {
      final mod = snapshot.module(module);
      if (!mod.hasUsableData) return;
      final obj = mod.objectData();
      if (obj == null) return;
      _cache.set(cacheKey, obj);
    }

    void seedAttendance() {
      final mod = snapshot.module('attendance');
      if (!mod.hasUsableData) return;
      final obj = mod.objectData();
      if (obj == null) return;
      final attendance = AttendanceResponse.fromJson(obj);
      if (attendance.items.any((item) => item.courseId.isEmpty)) return;
      _cache.set(_attendanceCacheKey(year: year, term: term), obj);
    }

    seedList('schedule', 'schedule_${year}_$term');
    seedList('grades', 'grades_${year}_$term');
    seedList('exams', 'exams_${year}_$term');
    seedObject('me', 'me');
    seedList('notices', 'notices');
    seedAttendance();
    seedList('credits', 'credits');
  }

  String _weatherCacheKey(double? lat, double? lon) {
    if (lat != null && lon != null) {
      return 'weather_${lat.toStringAsFixed(2)}_${lon.toStringAsFixed(2)}';
    }
    return 'weather';
  }

  Future<DataResult<List<NoticeItem>>> notices(
      {bool forceRefresh = false}) async {
    final result = await _cacheFirstList<NoticeItem>(
      cacheKey: 'notices',
      fetch: () => _plainList(
        _getList('/notices${forceRefresh ? '?refresh=true' : ''}'),
      ),
      fromJson: (json) => NoticeItem.fromJson(json),
      forceRefresh: forceRefresh,
      memoryTtl: const Duration(minutes: 2),
    );
    return DataResult<List<NoticeItem>>(
      data: result.data.where(_isReadableNoticeItem).toList(),
      source: result.source,
    );
  }

  List<NoticeItem>? cachedNotices() {
    final cached = _cache.get<List<dynamic>>('notices');
    return cached
        ?.whereType<Map<String, dynamic>>()
        .map(NoticeItem.fromJson)
        .where(_isReadableNoticeItem)
        .toList();
  }

  Future<DataResult<NoticeDetail>> fetchNoticeDetail(
    String url, {
    bool forceRefresh = false,
  }) =>
      _cacheFirstObject<NoticeDetail>(
        cacheKey: 'notice_detail_${Uri.encodeComponent(url)}',
        fetch: () => _plainObject(
          _get('/notices/detail?url=${Uri.encodeComponent(url)}'),
        ),
        fromJson: (json) => NoticeDetail.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<LeavePreviewResponse> previewLeave({
    required int year,
    required int term,
    required DateTime startDate,
    required DateTime endDate,
    required DateTime firstWeekStart,
    List<Map<String, dynamic>> courses = const [],
  }) async {
    final data = await _post('/ehall/leave/preview', {
      'year': year,
      'term': term,
      'startDate': dateText(startDate),
      'endDate': dateText(endDate),
      'firstWeekStart': dateText(firstWeekStart),
      if (courses.isNotEmpty) 'courses': courses,
    });
    return LeavePreviewResponse.fromJson(data);
  }

  Future<LeaveFillResponse> fillLeave({
    required int year,
    required int term,
    required DateTime startDate,
    required DateTime endDate,
    required DateTime firstWeekStart,
    required String reason,
    required List<PickedAttachment> attachments,
    List<MatchedTeacherItem> teacherHandlers = const [],
    List<Map<String, dynamic>> courses = const [],
  }) async {
    final data = await _post('/ehall/leave/fill', {
      'year': year,
      'term': term,
      'startDate': dateText(startDate),
      'endDate': dateText(endDate),
      'firstWeekStart': dateText(firstWeekStart),
      'reason': reason,
      'attachments': [
        for (final attachment in attachments)
          {
            'attachmentName': attachment.name,
            'attachmentContentBase64': base64Encode(attachment.bytes),
          },
      ],
      if (teacherHandlers.isNotEmpty)
        'teacherHandlers':
            teacherHandlers.map((item) => item.toJson()).toList(),
      if (courses.isNotEmpty) 'courses': courses,
    });
    return LeaveFillResponse.fromJson(data);
  }

  Future<List<StaffCandidateItem>> searchLeaveTeachers({
    required String keyword,
  }) async {
    final data = await _get(
      '/ehall/leave/teachers/search?keyword=${Uri.encodeQueryComponent(keyword)}',
    );
    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(StaffCandidateItem.fromJson)
        .toList();
  }

  Future<bool> uploadLeaveAttachment({
    required String docUnid,
    required String processId,
    required String nodeName,
    required String localStore,
    required String attachmentName,
    required Uint8List attachmentBytes,
  }) async {
    final data = await _post('/ehall/leave/attachment', {
      'docUnid': docUnid,
      'processId': processId,
      'nodeName': nodeName,
      'localStore': localStore,
      'attachmentName': attachmentName,
      'attachmentContentBase64': base64Encode(attachmentBytes),
    });
    return data['uploaded'] as bool? ?? false;
  }

  Future<List<EhallAffairItem>> ehallAffairs(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstList<EhallAffairItem>(
        cacheKey: 'ehall_affairs',
        fetch: () => _plainList(_getList('/ehall/affairs')),
        fromJson: (json) => EhallAffairItem.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 10),
      ))
          .data;

  Future<List<EhallApplicationItem>> ehallApplications(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstList<EhallApplicationItem>(
        cacheKey: 'ehall_applications',
        fetch: () => _plainList(_getList('/ehall/applications')),
        fromJson: (json) => EhallApplicationItem.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 10),
      ))
          .data;

  Future<EhallProgressOverview> ehallProgressOverview(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstObject<EhallProgressOverview>(
        cacheKey: 'ehall_progress_overview',
        fetch: () => _plainObject(_get('/ehall/progress')),
        fromJson: (json) => EhallProgressOverview.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 5),
      ))
          .data;

  Future<List<EhallProgressItem>> ehallProgress(
          {bool forceRefresh = false}) async =>
      (await ehallProgressOverview(forceRefresh: forceRefresh)).items;

  Future<List<EcardRoomItem>> ecardRooms({
    String? query,
    int limit = 100,
    bool forceRefresh = false,
  }) async {
    if (_isNativeMobile) {
      try {
        final direct = await _createEcardDirectClient().getRooms(
          query: query,
          limit: limit,
        );
        if (direct.isNotEmpty) return direct;
      } catch (_) {
        // Fall back to the backend cache below.
      }
    }
    final path = query != null && query.trim().isNotEmpty
        ? '/ecard/rooms?q=${Uri.encodeQueryComponent(query.trim())}&limit=$limit'
        : '/ecard/rooms?limit=$limit';
    try {
      final result = await _cacheFirstList<EcardRoomItem>(
        cacheKey: query != null && query.trim().isNotEmpty
            ? 'ecard_rooms_q_${query.trim().toLowerCase()}'
            : 'ecard_rooms',
        fetch: () => _plainList(_getList(path)),
        fromJson: (json) => EcardRoomItem.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 30),
      );
      return result.data;
    } catch (_) {
      if (!_isNativeMobile) rethrow;
      final direct = _createEcardDirectClient();
      return direct.getRooms(query: query, limit: limit);
    }
  }

  Future<DataResult<EcardSummary>> ecardSummary(
      {bool forceRefresh = false}) async {
    return _cacheFirstObject<EcardSummary>(
      cacheKey: 'ecard_summary',
      fetch: () => _plainObject(_get('/ecard/summary')),
      fromJson: (json) => EcardSummary.fromJson(json),
      forceRefresh: forceRefresh,
    );
  }

  Future<EcardSummary> bindEcardRoom(EcardRoomItem room) async {
    final data = await _post('/ecard/binding', {
      'roomId': room.id,
      'roomDisplay': room.displayName,
    });
    _cache.remove('ecard_rooms');
    _cache.set('ecard_summary', data);
    final pcache = await _getPersistentCache();
    await pcache.set('ecard_summary', data);
    await _invalidateDashboardCaches(pcache);
    return EcardSummary.fromJson(data);
  }

  Future<void> _invalidateDashboardCaches(PersistentCache pcache) async {
    const dashboardPrefix = 'dashboard_';
    _cache.removeStartingWith(dashboardPrefix);
    _backgroundRefreshes
        .removeWhere((key, _) => key.startsWith(dashboardPrefix));
    _backgroundRefreshAt
        .removeWhere((key, _) => key.startsWith(dashboardPrefix));
    await pcache.removeStartingWith(dashboardPrefix);
  }

  Future<EcardSummary> refreshEcard() async {
    final pcache = await _getPersistentCache();
    if (_isNativeMobile) {
      final cached = _cachedObject(pcache, 'ecard_summary') ??
          _cache.get<Map<String, dynamic>>('ecard_summary');
      if (cached != null) {
        final cachedSummary = EcardSummary.fromJson(cached);
        if (cachedSummary.isBound &&
            cachedSummary.roomId != null &&
            cachedSummary.roomId!.isNotEmpty) {
          return _enrichEcardSummaryDirect(cachedSummary, requireLive: true);
        }
      }
      final summary =
          await ecardSummary(forceRefresh: true).then((r) => r.data);
      return _enrichEcardSummaryDirect(summary, requireLive: true);
    }
    try {
      final data = await _post('/ecard/refresh', {});
      _cache.set('ecard_summary', data);
      await pcache.set('ecard_summary', data);
      return _enrichEcardSummaryDirect(EcardSummary.fromJson(data));
    } catch (e) {
      final cached = _cachedObject(pcache, 'ecard_summary') ??
          _cache.get<Map<String, dynamic>>('ecard_summary');
      if (cached != null) {
        // 刷新失败:不再静默吞掉,标记 stale 让页面提示当前为缓存数据
        final staleData = Map<String, dynamic>.of(cached)
          ..['stale'] = true
          ..['staleReason'] = e is ApiException ? e.message : '刷新失败';
        final direct =
            await _enrichEcardSummaryDirect(EcardSummary.fromJson(staleData));
        return direct;
      }
      rethrow;
    }
  }

  Future<EcardSummary> _enrichEcardSummaryDirect(EcardSummary summary,
      {bool requireLive = false}) async {
    if (!_isNativeMobile) return summary;
    if (!summary.isBound || summary.roomId == null || summary.roomId!.isEmpty) {
      return summary;
    }
    try {
      final balance = await _createEcardDirectClient()
          .getBalance(summary.roomId!, studentId: summary.studentId);
      if (balance == null) {
        if (requireLive) throw ApiException('水电余额刷新失败，请稍后重试');
        return summary;
      }
      final data = _ecardSummaryToJson(summary);
      data.addAll({
        'powerBalance': balance['powerBalance'],
        'powerUnit': balance['du'] ?? summary.powerUnit,
        'powerText': balance['formatPowerBalanceStr'] ??
            _formatEcardValue(
                balance['powerBalance'], balance['du'] ?? summary.powerUnit),
        'coldWaterBalance':
            balance['coldWaterBalance'] ?? balance['waterBalance'],
        'coldWaterUnit': balance['dun'] ?? summary.coldWaterUnit,
        'coldWaterText': balance['coldWaterText'] ??
            balance['formatWaterBalanceStr'] ??
            _formatEcardValue(
              balance['coldWaterBalance'] ?? balance['waterBalance'],
              balance['dun'] ?? summary.coldWaterUnit,
            ),
        'hotWaterBalance': balance['hotWaterBalance'],
        'hotWaterUnit': balance['hotWaterUnit'] ?? summary.hotWaterUnit,
        'hotWaterText': balance['hotWaterText'] ??
            balance['formatHotWaterBalanceStr'] ??
            _formatEcardValue(
              balance['hotWaterBalance'],
              balance['hotWaterUnit'] ?? summary.hotWaterUnit,
            ),
        'updatedAt': DateTime.now().toIso8601String(),
      });
      _cache.set('ecard_summary', data);
      final pcache = await _getPersistentCache();
      await pcache.set('ecard_summary', data);
      await _updateEcardSummaryCache(data);
      return EcardSummary.fromJson(data);
    } catch (_) {
      if (requireLive) rethrow;
      return summary;
    }
  }

  Future<void> _updateEcardSummaryCache(Map<String, dynamic> data) async {
    try {
      await _patch('/ecard/summary-cache', {
        'powerBalance': data['powerBalance'],
        'powerUnit': data['powerUnit'],
        'powerText': data['powerText'],
        'coldWaterBalance': data['coldWaterBalance'],
        'coldWaterUnit': data['coldWaterUnit'],
        'coldWaterText': data['coldWaterText'],
        'hotWaterBalance': data['hotWaterBalance'],
        'hotWaterUnit': data['hotWaterUnit'],
        'hotWaterText': data['hotWaterText'],
        'updatedAt': data['updatedAt'],
      });
    } catch (_) {
      // Local direct ecard data is still useful when backend cache sync fails.
    }
  }

  Map<String, dynamic> _ecardSummaryToJson(EcardSummary summary) => {
        'status': summary.status,
        'studentId': summary.studentId,
        'roomId': summary.roomId,
        'roomDisplay': summary.roomDisplay,
        'powerBalance': summary.powerBalance,
        'powerUnit': summary.powerUnit,
        'powerText': summary.powerText,
        'coldWaterBalance': summary.coldWaterBalance,
        'coldWaterUnit': summary.coldWaterUnit,
        'coldWaterText': summary.coldWaterText,
        'hotWaterBalance': summary.hotWaterBalance,
        'hotWaterUnit': summary.hotWaterUnit,
        'hotWaterText': summary.hotWaterText,
        'reminderEnabled': summary.reminderEnabled,
        'lowPowerThreshold': summary.lowPowerThreshold,
        'lowColdWaterThreshold': summary.lowColdWaterThreshold,
        'lowHotWaterThreshold': summary.lowHotWaterThreshold,
        'reminderTimes': summary.reminderTimes,
        'reminderItems': summary.reminderItems,
        'updatedAt': summary.updatedAt,
        'stale': summary.stale,
        'staleReason': summary.staleReason,
      };

  String? _formatEcardValue(dynamic value, dynamic unit) {
    if (value == null ||
        value.toString().isEmpty ||
        value.toString() == 'null') {
      return null;
    }
    return '$value ${unit ?? ''}'.trim();
  }

  Future<EcardSummary> updateEcardReminder({
    bool? enabled,
    double? lowPowerThreshold,
    double? lowColdWaterThreshold,
    double? lowHotWaterThreshold,
    List<String>? reminderTimes,
    List<String>? reminderItems,
  }) async {
    final data = await _patch('/ecard/reminder', {
      if (enabled != null) 'enabled': enabled,
      if (lowPowerThreshold != null) 'lowPowerThreshold': lowPowerThreshold,
      if (lowColdWaterThreshold != null)
        'lowColdWaterThreshold': lowColdWaterThreshold,
      if (lowHotWaterThreshold != null)
        'lowHotWaterThreshold': lowHotWaterThreshold,
      if (reminderTimes != null) 'reminderTimes': reminderTimes,
      if (reminderItems != null) 'reminderItems': reminderItems,
    });
    _cache.set('ecard_summary', data);
    final pcache = await _getPersistentCache();
    await pcache.set('ecard_summary', data);
    return EcardSummary.fromJson(data);
  }

  Future<EcardConsumptionResponse> ecardConsumption({String? month}) async {
    try {
      final path = month == null
          ? '/ecard/consumption'
          : '/ecard/consumption?month=$month';
      return EcardConsumptionResponse.fromJson(
        await _get(path).timeout(const Duration(seconds: 12)),
      );
    } on TimeoutException {
      return EcardConsumptionResponse.fromJson({
        'status': 'limited',
        'message': '消费记录加载超时，请稍后重试',
        'items': const [],
      });
    }
  }

  Future<EcardConsumptionOverviewResponse> ecardConsumptionOverview() async {
    return EcardConsumptionOverviewResponse.fromJson(
      await _get('/ecard/consumption/overview'),
    );
  }

  Future<List<Map<String, dynamic>>> pollPushMessages() async {
    final data = await _get('/push/poll');
    final messages = data['messages'];
    if (messages is! List<dynamic>) return const [];
    return [
      for (final item in messages)
        if (item is Map<String, dynamic>) item,
    ];
  }

  Future<Map<String, dynamic>> getWebPushConfig() async {
    final data = await _get('/push/web/config');
    return data;
  }

  Future<void> registerIosPushToken({
    required String deviceToken,
    required String environment,
  }) async {
    await _post('/push/ios/register', {
      'deviceToken': deviceToken,
      'environment': environment,
    });
  }

  Future<void> unregisterIosPushToken({
    required String activeSessionId,
    required String deviceToken,
    required String environment,
  }) async {
    await _postSessionCleanupWithBody(
      '/push/ios/unregister',
      activeSessionId,
      {
        'deviceToken': deviceToken,
        'environment': environment,
      },
    );
  }

  // ─── 管理后台 ──────────────────────────────────────────────
  // 所有 /admin/* 端点由 require_admin 鉴权（会话 is_admin 标记）。

  /// 当前会话的管理员身份与角色（会话恢复后确认 isAdmin 用）。
  Future<Map<String, dynamic>> adminMe() async => _get('/admin/me');

  /// 总览统计（会话/推送/水电费/缓存/管理员数量）。
  Future<Map<String, dynamic>> adminOverview() async => _get('/admin/overview');

  /// 会话列表（按创建时间倒序）。
  Future<Map<String, dynamic>> adminSessions(
          {int limit = 50, int offset = 0}) async =>
      _get('/admin/sessions?limit=$limit&offset=$offset');

  /// 强制下线一个会话。
  Future<Map<String, dynamic>> adminRevokeSession(String sessionId) async =>
      _post('/admin/sessions/$sessionId/revoke', const {});

  /// 管理员白名单列表。
  Future<Map<String, dynamic>> adminUsers() async => _get('/admin/users');

  /// 添加管理员（仅 owner）。
  Future<Map<String, dynamic>> adminAddUser(
          String studentId, String role) async =>
      _post('/admin/users', {'studentId': studentId, 'role': role});

  /// 删除管理员（仅 owner）。
  Future<Map<String, dynamic>> adminRemoveUser(String studentId) async =>
      _delete('/admin/users/$studentId');

  /// Web Push 订阅列表。
  Future<Map<String, dynamic>> adminPush({int limit = 50}) async =>
      _get('/admin/push?limit=$limit');

  /// 数据库缓存条目列表。
  Future<Map<String, dynamic>> adminCache(
          {int limit = 50, int offset = 0}) async =>
      _get('/admin/cache?limit=$limit&offset=$offset');

  /// 清空数据库缓存（可选按 resource 过滤）。
  Future<Map<String, dynamic>> adminClearCache({String? resource}) async {
    final query = resource != null ? '?resource=$resource' : '';
    return _post('/admin/cache/clear$query', const {});
  }

  /// 水电费绑定列表与统计。
  Future<Map<String, dynamic>> adminEcard(
          {int limit = 50, int offset = 0}) async =>
      _get('/admin/ecard?limit=$limit&offset=$offset');

  /// 系统状态（脱敏）。
  Future<Map<String, dynamic>> adminStatus() async => _get('/admin/status');

  /// 敏感操作审计日志。
  Future<Map<String, dynamic>> adminAuditLog({int limit = 50}) async =>
      _get('/admin/audit-log?limit=$limit');

  // ─── 管理后台 · 校历/通知上传 ─────────────────────────────

  /// 校历/通知列表（管理员视角，含未发布）。
  Future<Map<String, dynamic>> adminNotices(
          {int limit = 50, int offset = 0}) async =>
      _get('/admin/notices?limit=$limit&offset=$offset');

  /// 上传校历/通知（imageData 为 base64，可带 data:image/...;base64 前缀）。
  Future<Map<String, dynamic>> adminCreateNotice({
    required String title,
    String? description,
    String? imageData,
    String? imageMime,
    bool isPinned = false,
    bool published = true,
  }) =>
      _post('/admin/notices', {
        'title': title,
        'description': description,
        'imageData': imageData,
        'imageMime': imageMime,
        'isPinned': isPinned,
        'published': published,
      });

  /// 更新校历/通知。
  Future<Map<String, dynamic>> adminUpdateNotice(
    int noticeId, {
    String? title,
    String? description,
    String? imageData,
    String? imageMime,
    bool? isPinned,
    bool? published,
  }) =>
      _put('/admin/notices/$noticeId', {
        'title': title,
        'description': description,
        'imageData': imageData,
        'imageMime': imageMime,
        'isPinned': isPinned,
        'published': published,
      });

  /// 删除校历/通知。
  Future<Map<String, dynamic>> adminDeleteNotice(int noticeId) async =>
      _delete('/admin/notices/$noticeId');

  /// 未登录状态可读取的登录页轮播内容。
  Future<List<LoginCarouselSlide>> loginCarouselSlides() async {
    final items = await _getList('/content/login-slides');
    return items.map(LoginCarouselSlide.fromJson).toList();
  }

  // ─── 管理后台 · 登录页轮播 ─────────────────────────────

  Future<Map<String, dynamic>> adminLoginSlides() async =>
      _get('/admin/login-slides');

  Future<Map<String, dynamic>> adminCreateLoginSlide({
    required String title,
    required String imageData,
    required String imageMime,
    required bool published,
    String? description,
  }) =>
      _post('/admin/login-slides', {
        'title': title,
        'description': description,
        'imageData': imageData,
        'imageMime': imageMime,
        'published': published,
      });

  Future<Map<String, dynamic>> adminUpdateLoginSlide(
    int slideId, {
    String? title,
    String? description,
    String? imageData,
    String? imageMime,
    bool? published,
  }) =>
      _put('/admin/login-slides/$slideId', {
        'title': title,
        'description': description,
        'imageData': imageData,
        'imageMime': imageMime,
        'published': published,
      });

  Future<Map<String, dynamic>> adminReorderLoginSlides(List<int> ids) =>
      _put('/admin/login-slides/actions/order', {'ids': ids});

  Future<Map<String, dynamic>> adminDeleteLoginSlide(int slideId) async =>
      _delete('/admin/login-slides/$slideId');

  // ─── 管理后台 · 公众号文章 ─────────────────────────────

  /// 公众号同步通道状态（是否配置合集、上次同步时间）。
  Future<Map<String, dynamic>> adminWechatStatus() async =>
      _get('/admin/wechat/status');

  /// 立即同步公众号文章。
  Future<Map<String, dynamic>> adminWechatSync() async =>
      _post('/admin/wechat/sync', const {});

  /// 公众号文章列表（含隐藏）。
  Future<Map<String, dynamic>> adminWechatArticles(
          {int limit = 200, int offset = 0}) async =>
      _get('/admin/wechat/articles?limit=$limit&offset=$offset');

  /// 隐藏/取消隐藏公众号文章。
  Future<Map<String, dynamic>> adminWechatSetHidden(
      int articleId, bool hidden) async {
    final action = hidden ? 'hide' : 'unhide';
    return _post('/admin/wechat/articles/$articleId/$action', const {});
  }

  /// 删除公众号文章。
  Future<Map<String, dynamic>> adminWechatDelete(int articleId) async =>
      _delete('/admin/wechat/articles/$articleId');

  /// 粘贴公众号文章链接导入。
  Future<Map<String, dynamic>> adminWechatImport(String url) async =>
      _post('/admin/wechat/import', {'url': url});

  /// 把后端返回的相对路径（如校历图片 /admin/notices/1/image）拼成完整 URL。
  String resolveMediaUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final trimmed = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$trimmed${path.startsWith('/') ? path : '/$path'}';
  }

  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const int _maxRetries = 1;

  Future<Map<String, dynamic>> _get(String path) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  DataSourceInfo _sourceFromResponse(http.Response response) {
    if (response.headers['x-data-source'] != 'cache') {
      return const DataSourceInfo();
    }
    return DataSourceInfo(
      fromCache: true,
      cachedAt: DateTime.tryParse(response.headers['x-data-cached-at'] ?? ''),
      isOffline: true,
    );
  }

  Future<_Fetched<Map<String, dynamic>>> _getObjectWithSource(
    String path,
  ) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _Fetched(
          data: _decodeObject(response),
          source: _sourceFromResponse(response),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        final decoded = _decode(response);
        if (decoded is! List<dynamic>) {
          throw ApiException('服务器返回了意外的数据格式');
        }
        return decoded.whereType<Map<String, dynamic>>().toList();
      },
    );
  }

  Future<_Fetched<List<Map<String, dynamic>>>> _getListWithSource(
    String path,
  ) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        final decoded = _decode(response);
        if (decoded is! List<dynamic>) {
          throw ApiException('服务器返回了意外的数据格式');
        }
        return _Fetched(
          data: decoded.whereType<Map<String, dynamic>>().toList(),
          source: _sourceFromResponse(response),
        );
      },
    );
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    return _withReloginRetry(() => _postWithoutRelogin(path, body));
  }

  Future<Map<String, dynamic>> _postWithoutRelogin(
      String path, Map<String, dynamic> body) async {
    final url = _requireBaseUrl();
    final response = await _http
        .post(
          Uri.parse('$url$path'),
          headers: _headers(),
          body: jsonEncode(body),
        )
        .timeout(_connectTimeout)
        .timeout(_requestTimeout);
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> _patch(
      String path, Map<String, dynamic> body) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .patch(
              Uri.parse('$url$path'),
              headers: _headers(),
              body: jsonEncode(body),
            )
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  Future<Map<String, dynamic>> _put(
      String path, Map<String, dynamic> body) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .put(
              Uri.parse('$url$path'),
              headers: _headers(),
              body: jsonEncode(body),
            )
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .delete(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  Future<Map<String, dynamic>> _getDashboardObject(String path) async {
    final url = _requireBaseUrl();
    final response = await _http
        .get(Uri.parse('$url$path'), headers: _headers())
        .timeout(const Duration(seconds: 12));
    if (response.statusCode >= 400) {
      // 错误响应通常很小，直接走统一错误语义
      return _decodeObject(response);
    }
    // dashboard 聚合响应较大（全学期课表/成绩/考试/考勤），
    // JSON 解码放到后台 isolate，避免主 isolate 掉帧
    final body = utf8.decode(response.bodyBytes);
    final dynamic decoded = await compute(_decodeJsonString, body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('服务器返回了意外的数据格式');
    }
    return decoded;
  }

  String _requireBaseUrl() {
    if (baseUrl.isEmpty) {
      throw ApiException('未配置 API_BASE_URL，请使用腾讯云 API 地址重新构建应用');
    }
    return baseUrl;
  }

  Future<void>? _warmupFuture;
  bool _warmedUp = false;
  bool _warmupDisposed = false;

  void startWarmup() {
    if (_warmupDisposed) return;
    if (_warmedUp || _warmupFuture != null) return;
    _warmupFuture = _doWarmup();
  }

  void dispose() {
    _warmupDisposed = true;
  }

  Future<void> _doWarmup() async {
    try {
      final healthy = await checkHealth();
      if (!_warmupDisposed && healthy) {
        unawaited(fetchPublicKey());
      }
    } finally {
      if (!_warmupDisposed) {
        _warmedUp = true;
      }
      _warmupFuture = null;
    }
  }

  /// 在收到 401 时自动尝试 relogin 并重试原始请求
  Future<T> _withReloginRetry<T>(Future<T> Function() request) async {
    return _withRetry(request, retryCount: 0);
  }

  /// 在唯一生产 API 上有限重试；不再切换旧域名或边缘节点。
  Future<T> _withRetry<T>(
    Future<T> Function() request, {
    int retryCount = 0,
  }) async {
    if (_offlineScheduleStudentId != null) {
      throw ApiException('登录状态已失效，请重新登录', statusCode: 401);
    }
    try {
      return await request();
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await loadSavedCredentials();
        if (_credentialToken == null) {
          await enterScheduleOnlyMode();
          onReloginFailed?.call();
          throw ApiException('登录已过期，请重新登录', statusCode: 401);
        }
        final inFlightRelogin = _reloginFuture;
        if (inFlightRelogin != null) {
          await inFlightRelogin;
          return request();
        }
        // --- Relogin with backoff ---
        // Avoid hammering CAS if relogin keeps failing.
        final now = DateTime.now();
        final backoffSeconds = (_reloginMinInterval.inSeconds *
                (1 << _consecutiveReloginFailures.clamp(0, 4)))
            .clamp(_reloginMinInterval.inSeconds, _reloginMaxBackoffSeconds);
        if (_lastReloginAttempt != null &&
            now.difference(_lastReloginAttempt!) <
                Duration(seconds: backoffSeconds)) {
          // Too soon to retry — rethrow so the caller sees the 401
          throw ApiException('登录状态已失效，请重新登录', statusCode: 401);
        }
        _lastReloginAttempt = now;
        bool reloginSucceeded = false;
        try {
          await relogin();
          reloginSucceeded = true;
          _consecutiveReloginFailures = 0; // reset on success
        } on ApiException catch (e) {
          _consecutiveReloginFailures++;
          // 只有服务端明确要求重新验证（401）才清除本设备凭据。
          // CAS/网络上游故障（5xx）保留凭据，稍后可继续自动恢复。
          if (e.statusCode == 401) {
            await enterScheduleOnlyMode();
            onReloginFailed?.call();
          }
          rethrow;
        } catch (_) {
          _consecutiveReloginFailures++;
          rethrow;
        }
        // relogin 成功，重试原始请求
        if (reloginSucceeded) {
          // 重试请求，如果仍然 401 说明该 API 需要特殊权限（如 ehall），
          // 不是 session 过期问题，直接抛出异常
          try {
            return await request();
          } on ApiException {
            // 重登成功后原接口仍 401，通常是该接口自己的权限/会话问题。
            // 保留全局登录态，让页面展示错误或缓存数据。
            rethrow;
          }
        }
      }
      // 5xx 错误只在同一生产 API 上重试一次。
      if ((e.statusCode ?? 0) >= 500 && retryCount < _maxRetries) {
        return _withRetry(request, retryCount: retryCount + 1);
      }
      rethrow;
    } on TimeoutException {
      // 超时后只在同一生产 API 上重试一次。
      if (retryCount < _maxRetries) {
        return _withRetry(request, retryCount: retryCount + 1);
      }
      throw ApiException('请求超时 ($baseUrl)，请检查网络连接');
    } on http.ClientException {
      // 连接失败后只在同一生产 API 上重试一次。
      if (retryCount < _maxRetries) {
        return _withRetry(request, retryCount: retryCount + 1);
      }
      throw ApiException('无法连接服务器 ($baseUrl)，请确认服务已启动且设备在同一网络');
    } on SocketException {
      // Socket 失败后只在同一生产 API 上重试一次。
      if (retryCount < _maxRetries) {
        return _withRetry(request, retryCount: retryCount + 1);
      }
      throw ApiException('无法连接服务器 ($baseUrl)，请确认服务已启动且设备在同一网络');
    }
  }

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
        'X-Client-Platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'X-GZUS-Trace-Id': _newTraceId(),
        if (sessionId != null) 'X-Session-Id': sessionId!,
      };

  Map<String, String> _headersForSession(String activeSessionId) => {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
        'X-Client-Platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'X-GZUS-Trace-Id': _newTraceId(),
        'X-Session-Id': activeSessionId,
      };

  Future<void> _postSessionCleanup(
    String path,
    String activeSessionId,
  ) async {
    final url = _requireBaseUrl();
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await _http
            .post(
              Uri.parse('$url$path'),
              headers: _headersForSession(activeSessionId),
              body: jsonEncode({}),
            )
            .timeout(const Duration(seconds: 10));
        _decodeObject(response);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        final sessionPrefix = activeSessionId.length <= 8
            ? activeSessionId
            : activeSessionId.substring(0, 8);
        debugPrint(
          '会话清理请求失败: path=$path, attempt=$attempt, '
          'session=$sessionPrefix, '
          'error=${error.runtimeType}',
        );
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> _postSessionCleanupWithBody(
    String path,
    String activeSessionId,
    Map<String, dynamic> body,
  ) async {
    final url = _requireBaseUrl();
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await _http
            .post(
              Uri.parse('$url$path'),
              headers: _headersForSession(activeSessionId),
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 10));
        _decodeObject(response);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        final sessionPrefix = activeSessionId.length <= 8
            ? activeSessionId
            : activeSessionId.substring(0, 8);
        debugPrint(
          '会话清理请求失败: path=$path, attempt=$attempt, '
          'session=$sessionPrefix, '
          'error=${error.runtimeType}',
        );
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  String _newTraceId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final ns = namespace.hashCode.toUnsigned(20).toRadixString(36);
    return 'gz-$now-$ns';
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('服务器返回了意外的数据格式');
    }
    return decoded;
  }

  dynamic _decode(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      if (response.statusCode >= 500) {
        throw ApiException('服务暂时不可用，请稍后重试', statusCode: response.statusCode);
      }
      throw ApiException(body.trim().isEmpty ? '请求失败' : body.trim(),
          statusCode: response.statusCode);
    }
    if (response.statusCode >= 400) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(
        detail?.toString() ?? '请求失败',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }
}

/// 顶层函数：供 compute() 在后台 isolate 中执行 JSON 解码
dynamic _decodeJsonString(String body) => jsonDecode(body);

List<int> parseWeeks(String? weeks) {
  if (weeks == null || weeks.trim().isEmpty) return [];
  final normalized = weeks
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('，', ',')
      .replaceAll('；', ';')
      .replaceAll('、', ',');
  final result = <int>{};
  for (final segment in normalized.split(RegExp(r'[,;]'))) {
    final text = segment.trim();
    if (text.isEmpty) continue;
    final oddOnly = text.contains('单');
    final evenOnly = text.contains('双');
    final ranges = RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(text).toList();
    if (ranges.isNotEmpty) {
      for (final match in ranges) {
        final start = int.tryParse(match.group(1)!);
        final end = int.tryParse(match.group(2)!);
        if (start != null && end != null) {
          for (var w = start; w <= end; w++) {
            if (oddOnly && w.isEven) continue;
            if (evenOnly && w.isOdd) continue;
            result.add(w);
          }
        }
      }
      continue;
    }
    for (final match in RegExp(r'\d+').allMatches(text)) {
      final w = int.tryParse(match.group(0)!);
      if (w != null) {
        if (oddOnly && w.isEven) continue;
        if (evenOnly && w.isOdd) continue;
        result.add(w);
      }
    }
  }
  return result.toList()..sort();
}

String generateIcs({
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required int year,
  required int term,
}) {
  final lines = <String>[];
  lines.add('BEGIN:VCALENDAR');
  lines.add('PRODID:-//OneGZUS//Schedule//CN');
  lines.add('VERSION:2.0');
  for (final course in courses) {
    if (course.weekday == null ||
        course.startSection == null ||
        course.endSection == null) {
      continue;
    }
    final weeks = parseWeeks(course.weeks);
    final startTime = scheduleTimes[course.startSection! - 1].$1;
    final endTime = scheduleTimes[course.endSection! - 1].$2;
    for (final week in weeks) {
      // 对齐到第一周所在周的周一，确保非周一日期也能正确生成 ICS
      final mondayOfFirstWeek = firstWeekStart
          .subtract(Duration(days: firstWeekStart.weekday - DateTime.monday));
      final date = mondayOfFirstWeek
          .add(Duration(days: (week - 1) * 7 + (course.weekday! - 1)));
      final dateStr =
          '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      lines.add('BEGIN:VEVENT');
      lines.add(
          'UID:gzus-${course.name.hashCode.abs()}-$week-${course.weekday}@onegzus');
      lines.add('DTSTART:${dateStr}T${startTime.replaceAll(':', '')}00');
      lines.add('DTEND:${dateStr}T${endTime.replaceAll(':', '')}00');
      lines.add('SUMMARY:${course.name}');
      if (course.classroom != null && course.classroom!.isNotEmpty) {
        lines.add('LOCATION:${course.classroom}');
      }
      if (course.teacher != null && course.teacher!.isNotEmpty) {
        lines.add('DESCRIPTION:教师: ${course.teacher}');
      }
      lines.add('END:VEVENT');
    }
  }
  lines.add('END:VCALENDAR');
  return lines.join('\r\n');
}

String generateExamIcs({
  required List<PeriodExam> exams,
  required int year,
  required int term,
}) {
  final lines = <String>[];
  lines.add('BEGIN:VCALENDAR');
  lines.add('PRODID:-//OneGZUS//Exams//CN');
  lines.add('VERSION:2.0');
  for (final pe in exams) {
    final exam = pe.exam;
    lines.add('BEGIN:VEVENT');
    lines.add(
        'UID:gzus-exam-${exam.courseName.hashCode.abs()}-${pe.period.year}-${pe.period.term}@onegzus');
    lines.add('SUMMARY:${exam.courseName} 考试');
    final parsed = parseExamDateRange(exam.time);
    if (parsed != null) {
      lines.add('DTSTART:${_dateTimeToIcs(parsed.$1)}');
      lines.add('DTEND:${_dateTimeToIcs(parsed.$2)}');
    }
    if (exam.location != null && exam.location!.isNotEmpty) {
      lines.add('LOCATION:${exam.location}');
    }
    final descParts = <String>[];
    if (exam.time != null) descParts.add('时间: ${exam.time}');
    if (exam.type != null) descParts.add('类型: ${exam.type}');
    if (exam.seat != null) descParts.add('座位: ${exam.seat}');
    if (descParts.isNotEmpty) {
      lines.add('DESCRIPTION:${descParts.join(' \\n ')}');
    }
    lines.add('END:VEVENT');
  }
  lines.add('END:VCALENDAR');
  return lines.join('\r\n');
}

String _dateTimeToIcs(DateTime value) {
  final date = '${value.year}${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}';
  final time = '${value.hour.toString().padLeft(2, '0')}'
      '${value.minute.toString().padLeft(2, '0')}';
  return '${date}T${time}00';
}

DateTime _dateTimeAtScheduleTime(DateTime date, String time) {
  final parts = time.split(':');
  return DateTime(
    date.year,
    date.month,
    date.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

/// 把课表展开成可直接写入系统日历的日程列表。
List<CalendarImportEvent> scheduleCalendarEvents({
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required int year,
  required int term,
}) {
  final events = <CalendarImportEvent>[];
  final mondayOfFirstWeek = mondayOf(firstWeekStart);
  for (final course in courses) {
    if (course.weekday == null ||
        course.startSection == null ||
        course.endSection == null) {
      continue;
    }
    final weeks = parseWeeks(course.weeks);
    for (final week in weeks) {
      final date = mondayOfFirstWeek
          .add(Duration(days: (week - 1) * 7 + course.weekday! - 1));
      final start = _dateTimeAtScheduleTime(
        date,
        scheduleTimes[course.startSection! - 1].$1,
      );
      final end = _dateTimeAtScheduleTime(
        date,
        scheduleTimes[course.endSection! - 1].$2,
      );
      final descParts = <String>[];
      if (course.teacher != null && course.teacher!.isNotEmpty) {
        descParts.add('教师: ${course.teacher}');
      }
      if (course.weeks != null && course.weeks!.isNotEmpty) {
        descParts.add('周次: ${course.weeks}');
      }
      events.add(
        CalendarImportEvent(
          title: course.name,
          description: descParts.isEmpty ? null : descParts.join('\n'),
          location: course.classroom != null && course.classroom!.isNotEmpty
              ? course.classroom
              : null,
          start: start,
          end: end,
        ),
      );
    }
  }
  return events;
}

/// 把考试列表转换成可直接写入系统日历的日程列表。
List<CalendarImportEvent> examCalendarEvents({
  required List<PeriodExam> exams,
  required int year,
  required int term,
}) {
  final events = <CalendarImportEvent>[];
  for (final pe in exams) {
    final exam = pe.exam;
    final range = parseExamDateRange(exam.time);
    if (range == null) continue;
    final descParts = <String>[];
    if (exam.time != null) descParts.add('时间: ${exam.time}');
    if (exam.type != null) descParts.add('类型: ${exam.type}');
    if (exam.seat != null) descParts.add('座位: ${exam.seat}');
    events.add(
      CalendarImportEvent(
        title: '${exam.courseName} 考试',
        description: descParts.isEmpty ? null : descParts.join('\n'),
        location: exam.location != null && exam.location!.isNotEmpty
            ? exam.location
            : null,
        start: range.$1,
        end: range.$2,
      ),
    );
  }
  return events;
}

// Direct JWXT API client for native mobile foreground reads.
class SchoolDirectClient {
  SchoolDirectClient({
    required this.cookies,
    required this.account,
    required http.Client httpClient,
  }) : _http = httpClient;

  static const _base = 'https://jwxt.gzus.edu.cn/jwglxt';
  final String cookies;
  final String? account;
  final http.Client _http;

  Future<List<Map<String, dynamic>>> schedule({
    required int year,
    required int term,
  }) async {
    final data = await _postJson(
      '$_base/kbcx/xskbcx_cxXsKb.html',
      _academicParams(year: year, term: term)..['kzlx'] = 'ck',
    );
    return _normalizeList(
        _extractList(data, preferredKey: 'kbList'), 'schedule');
  }

  Future<List<Map<String, dynamic>>> exams({
    required int year,
    required int term,
  }) async {
    final data = await _postJson(
      '$_base/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105',
      _academicParams(year: year, term: term)
        ..addAll({
          'ksmcdmb_id': '',
          'kch': '',
          'kc': '',
          'ksrq': '',
        }),
    );
    return _normalizeList(_extractList(data), 'exams');
  }

  Future<List<Map<String, dynamic>>> grades({
    required int year,
    required int term,
  }) async {
    final data = await _postJson(
      '$_base/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005',
      _academicParams(year: year, term: term)
        ..addAll({
          'kch': '',
          'kc': '',
        }),
    );
    return _normalizeList(_extractList(data), 'grades');
  }

  Future<Map<String, dynamic>> attendance({
    required int year,
    required int term,
  }) async {
    final studentId = account;
    if (studentId == null || studentId.isEmpty) {
      throw ApiException('缺少学号，无法直连考勤');
    }
    final data = await _postJson(
      '$_base/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html?doType=query&gnmkdm=N254315',
      {
        'xh': studentId,
        'xm': '',
        'xh_id': '',
        'xnm': '$year',
        'xqm': _termCode(term),
        'kch': '',
        'kch_id': '',
        'gnmkdm': 'N254315',
        'queryModel.showCount': '100',
        'queryModel.currentPage': '1',
        'queryModel.sortName': '',
        'queryModel.sortOrder': 'asc',
      },
    );
    return {
      'status': 'ok',
      'items': _normalizeList(_extractList(data), 'attendance'),
    };
  }

  Future<List<Map<String, dynamic>>> credits() async {
    final studentId = account;
    if (studentId == null || studentId.isEmpty) {
      throw ApiException('缺少学号，无法直连学分');
    }
    final data = await _postJson(
      '$_base/design/funcData_cxFuncDataList.html?func_widget_guid=37234863CD24BB76E063860810AC3761&gnmkdm=N255022',
      {
        'gnmkdm': 'N255022',
        'xh': studentId,
        'queryModel.showCount': '15',
        'queryModel.currentPage': '1',
        'queryModel.sortName': ' ',
        'queryModel.sortOrder': 'asc',
      },
    );
    final list = _extractList(data);
    if (list.isNotEmpty) return _normalizeList(list, 'credits');
    if (_isEmptyResult(data)) return const [];
    if (data.isNotEmpty) return [_normalizeCreditItem(data)];
    return const [];
  }

  Map<String, String> _academicParams({
    required int year,
    required int term,
  }) =>
      {
        'xnm': '$year',
        'xqm': _termCode(term),
        '_search': 'false',
        'nd': '${DateTime.now().millisecondsSinceEpoch}',
        'queryModel.showCount': '100',
        'queryModel.currentPage': '1',
        'queryModel.sortName': '',
        'queryModel.sortOrder': 'asc',
        'time': '1',
      };

  static String _termCode(int term) {
    const termMap = {1: '3', 2: '12', 3: '16'};
    return termMap[term] ?? '';
  }

  Future<Map<String, dynamic>> _postJson(
    String url,
    Map<String, String> body,
  ) async {
    final response = await _http
        .post(
          Uri.parse(url),
          headers: {
            'Cookie': cookies,
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
            'Referer': '$_base/xtgl/index_initMenu.html',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 400) {
      throw ApiException('教务系统直连失败', statusCode: response.statusCode);
    }
    final text = _decodeAcademicBody(response.bodyBytes);
    if (_looksLikeLoginPage(text)) {
      throw ApiException('登录状态已失效', statusCode: 401);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('教务系统返回了意外的数据格式');
    }
    return decoded;
  }

  String _decodeAcademicBody(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return gbk.decode(bytes);
    }
  }

  bool _looksLikeLoginPage(String value) =>
      value.contains('login_slogin') ||
      RegExp("<input[^>]*type\\s*=\\s*[\"']password[\"']", caseSensitive: false)
          .hasMatch(value);

  List<Map<String, dynamic>> _extractList(
    Map<String, dynamic> data, {
    String? preferredKey,
  }) {
    final keys = [
      if (preferredKey != null) preferredKey,
      'items',
      'rows',
      'list',
      'data',
    ];
    for (final key in keys) {
      final value = data[key];
      if (value is List<dynamic>) {
        return value.whereType<Map<String, dynamic>>().toList();
      }
      if (value is Map<String, dynamic>) {
        final nested = _extractList(value);
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  List<Map<String, dynamic>> _normalizeList(
    List<Map<String, dynamic>> items,
    String path,
  ) =>
      [
        for (final item in items)
          switch (path) {
            'schedule' => _normalizeScheduleCourse(item),
            'exams' => _normalizeExamItem(item),
            'grades' => _normalizeGradeItem(item),
            'attendance' => _normalizeAttendanceItem(item),
            'credits' => _normalizeCreditItem(item),
            _ => item,
          }
      ];

  Map<String, dynamic> _normalizeGradeItem(Map<String, dynamic> item) => {
        'courseName': item['kcmc'] ?? item['courseName'] ?? item['name'] ?? '',
        'score': _stringOrNull(item['cj']) ?? item['score'],
        'credit': _stringOrNull(item['xf']) ?? item['credit'],
        'gradePoint': _stringOrNull(item['jd']) ?? item['gradePoint'],
        'term': item['xqmc'] ?? item['xq'] ?? item['term'],
      };

  Map<String, dynamic> _normalizeScheduleCourse(Map<String, dynamic> item) {
    final range = _parseSectionRange(
      item['ksjc'] ?? item['jcs'] ?? item['jc'] ?? item['startSection'],
    );
    final explicitEnd = _parseSectionRange(
      item['jsjc'] ??
          item['endSection'] ??
          item['end_section'] ??
          item['jc_end'],
    ).$2;
    return {
      'name': item['kcmc'] ?? item['name'] ?? item['courseName'] ?? '',
      'teacher': item['jsxx'] ?? item['jsxm'] ?? item['xm'] ?? item['teacher'],
      'classroom': item['cdmc'] ?? item['classroom'] ?? item['location'],
      'weekday': item['xqj'] ?? item['weekday'] ?? item['weekDay'],
      'startSection': range.$1 ?? item['startSection'],
      'endSection': explicitEnd ?? range.$2 ?? item['endSection'],
      'weeks': item['zcd'] ?? item['weeks'] ?? item['week'],
      'kcbmc': item['kcbmc'],
      'raw': item,
    };
  }

  Map<String, dynamic> _normalizeExamItem(Map<String, dynamic> item) {
    final rawTime =
        (item['kssj'] ?? item['time'] ?? item['examTime'] ?? '').toString();
    var date = (item['date'] ?? item['examDate'] ?? '').toString();
    if (date.length < 8 && rawTime.isNotEmpty) {
      final parenIdx = rawTime.indexOf('(');
      final spaceIdx = rawTime.indexOf(' ');
      final sepIdx = parenIdx > 0 ? parenIdx : (spaceIdx > 0 ? spaceIdx : -1);
      if (sepIdx > 0) {
        date = rawTime.substring(0, sepIdx);
      } else if (rawTime.length >= 10 && rawTime[4] == '-') {
        date = rawTime.substring(0, 10);
      }
    }
    var weekday =
        (item['weekday'] ?? item['weekDay'] ?? item['xqj'] ?? '').toString();
    if (weekday.isEmpty && date.isNotEmpty) {
      final parsed = DateTime.tryParse(date);
      const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      if (parsed != null) weekday = names[parsed.weekday - 1];
    }
    final name = item['kcmc'] ?? item['courseName'] ?? item['name'] ?? '';
    return {
      'courseName': name,
      'name': name,
      'date': date,
      'weekday': weekday,
      'time': rawTime.replaceAll('(', ' ').replaceAll(')', ''),
      'location': item['cdmc'] ?? item['location'] ?? item['examPlace'],
      'seat': _stringOrNull(item['zwh']) ?? item['seat'] ?? item['seatNo'],
      'type': item['ksmc'] ?? item['ksfs'] ?? item['type'] ?? item['kslx'],
      'credit': _stringOrNull(item['xf']) ?? item['credit'] ?? '',
      'campus': item['cdxqmc'] ?? item['campus'],
      'remark': item['ksbz'] ?? item['remark'],
    };
  }

  Map<String, dynamic> _normalizeAttendanceItem(Map<String, dynamic> item) => {
        'courseId': _stringOrNull(item['kch_id'] ?? item['courseId']) ?? '',
        'courseName': item['kcmc'] ?? item['courseName'] ?? item['name'] ?? '',
        'courseCode': item['kch'] ?? item['courseCode'],
        'academicYear': item['xnmc'] ?? item['xn'] ?? item['academicYear'],
        'term': '${item['xqmc'] ?? item['xq'] ?? item['term'] ?? ''}',
        'normal': _intDirect(item['cs_01'] ?? item['normal']),
        'late': _intDirect(item['cs_02'] ?? item['late']),
        'leaveEarly': _intDirect(item['cs_03'] ?? item['leaveEarly']),
        'absent': _intDirect(item['cs_04'] ?? item['absent']),
        'leave': _intDirect(item['cs_05'] ?? item['leave']),
        'total': _intDirect(item['totalresult'] ?? item['total']),
        'records': const [],
      };

  Map<String, dynamic> _normalizeCreditItem(Map<String, dynamic> item) {
    final reqExp = _doubleDirect(item['yqxf_01'] ?? item['requiredExpected']);
    final eleExp = _doubleDirect(item['yqxf_02'] ?? item['electiveExpected']);
    final othExp = _doubleDirect(item['yqxf_03'] ?? item['otherExpected']);
    final reqEar = _doubleDirect(item['sxxf_01'] ?? item['requiredEarned']);
    final eleEar = _doubleDirect(item['sxxf_02'] ?? item['electiveEarned']);
    final othEar = _doubleDirect(item['sxxf_03'] ?? item['otherEarned']);
    return {
      'studentId': '${item['xh'] ?? item['studentId'] ?? ''}',
      'name': item['xm'] ?? item['name'],
      'college': item['jgmc'] ?? item['college'],
      'major': item['zymc'] ?? item['major'],
      'grade': '${item['nj'] ?? item['grade'] ?? ''}',
      'totalCredit': '${item['zdxf'] ?? item['totalCredit'] ?? ''}',
      'requiredCredit': '${item['bxxf'] ?? item['requiredCredit'] ?? ''}',
      'selectedCredit': '${item['xkxf'] ?? item['selectedCredit'] ?? ''}',
      'requiredExpected': reqExp,
      'electiveExpected': eleExp,
      'otherExpected': othExp,
      'requiredEarned': reqEar,
      'electiveEarned': eleEar,
      'otherEarned': othEar,
      'totalExpected': reqExp + eleExp + othExp,
      'totalEarned': reqEar + eleEar + othEar,
    };
  }

  (int?, int?) _parseSectionRange(dynamic value) {
    if (value == null) return (null, null);
    final numbers = RegExp(r'\d+')
        .allMatches('$value')
        .map((match) => int.tryParse(match.group(0)!))
        .whereType<int>()
        .toList();
    if (numbers.isEmpty) return (null, null);
    if (numbers.length == 1) return (numbers.first, numbers.first);
    return (numbers.first, numbers[1]);
  }

  String? _stringOrNull(dynamic value) => value == null ? null : '$value';
  int _intDirect(dynamic value) => int.tryParse('${value ?? 0}') ?? 0;
  double _doubleDirect(dynamic value) => double.tryParse('${value ?? 0}') ?? 0;
  bool _isEmptyResult(Map<String, dynamic> data) =>
      int.tryParse('${data['totalResult'] ?? data['totalCount'] ?? -1}') == 0;
}

// ============================================================
// Direct ecard API client — calls ecarduser.gzus.edu.cn from the user's device.
// ============================================================
class EcardDirectClient {
  static const _base = 'https://ecarduser.gzus.edu.cn';
  static const _secret = 'greatge';
  static const _openid = 'o6gXt5YdtSc-15PgJg0KqAXZytRc';
  static const _ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Mobile/15E148 MicroMessenger/8.0.38 NetType/WIFI Language/zh_CN';

  // Static token cache — shared across all EcardDirectClient instances within
  // the same app session. Avoids re-login on every API call.
  static String? _cachedToken;
  static String? _cachedUnionid;
  static DateTime? _cachedAt;
  static const _tokenTtl = Duration(minutes: 50);

  String? get _token =>
      (_cachedAt != null && DateTime.now().difference(_cachedAt!) < _tokenTtl)
          ? _cachedToken
          : null;
  set _token(String? v) {
    _cachedToken = v;
    _cachedAt = DateTime.now();
  }

  void _invalidateToken() {
    _cachedToken = null;
    _cachedUnionid = null;
    _cachedAt = null;
  }

  static String _md5(String s) {
    // Pure Dart MD5
    return _md5String(s).toLowerCase();
  }

  static String _sign(Map<String, String> params) {
    final filtered = Map.of(params)
      ..remove('token')
      ..remove('sign');
    final keys = filtered.keys.toList()..sort();
    final raw = '${keys.map((k) => '$k=${filtered[k]}').join('&')}&$_secret';
    return _md5(raw).toUpperCase();
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, String> params) async {
    final activeToken = _token;
    params['from'] ??= 'wxminiprogram';
    params['isWxEnterpriseXcx'] ??= 'false';
    params['wxRequest'] ??= 'wxRequest';
    params['openid'] = _openid;
    if (activeToken != null &&
        activeToken.isNotEmpty &&
        _cachedUnionid != null &&
        _cachedUnionid!.isNotEmpty) {
      params['unionid'] = _cachedUnionid!;
    }
    if (activeToken != null && activeToken.isNotEmpty) {
      params['token'] = activeToken;
    }
    params['sign'] = _sign(params);

    final uri = Uri.parse('$_base/$path');
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': _ua
          },
          body: params,
        )
        .timeout(const Duration(seconds: 15));
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    final decoded = jsonDecode(body);
    if (response.statusCode >= 400) {
      throw ApiException('一卡通服务请求失败', statusCode: response.statusCode);
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('一卡通服务响应异常');
    }
    return decoded;
  }

  Future<bool> login() async {
    final r =
        await _post('user/routine/routine-login', {'from': 'wxminiprogram'});
    if (r['code'] == 200 && r['token'] != null) {
      _token = r['token'].toString();
      if (r['unionid'] != null) _cachedUnionid = r['unionid'].toString();
      return true;
    }
    return false;
  }

  Future<List<EcardRoomItem>> getRooms({String? query, int limit = 100}) async {
    if (_token == null && !await login()) return [];

    final items = <EcardRoomItem>[];
    final seen = <String>{};
    final seenPhysical = <String>{};
    final errors = <Object>[];
    for (final impl in ['CGCOMMON1111', 'CGCOMMON2222', 'CGCOMMON3333']) {
      try {
        var r = await _post('powerfee/getRoomInfo', {'implType': impl});
        // Retry on auth failure (code=203 or "未登录")
        if (r['code'] == 203 || '${r['msg']}'.contains('未登录')) {
          _invalidateToken();
          if (!await login()) return [];
          r = await _post('powerfee/getRoomInfo', {'implType': impl});
        }
        if (!_isEcardOk(r)) {
          errors.add(ApiException('${r['msg'] ?? '获取宿舍列表失败'}'));
          continue;
        }
        final obj = r['obj'];
        if (obj is! List) continue;
        for (final room in obj) {
          if (room is! Map) continue;
          final effectiveImpl = '${room['implType'] ?? ''}'.isEmpty
              ? impl
              : '${room['implType']}';
          final schoolAreaNo = '${room['schoolAreaNo'] ?? ''}';
          final buildingNo = '${room['buildingNo'] ?? ''}';
          final roomNum = '${room['roomNum'] ?? ''}';
          final hasPhysicalKey = schoolAreaNo.isNotEmpty &&
              buildingNo.isNotEmpty &&
              roomNum.isNotEmpty;
          final physicalKey = '$schoolAreaNo|$buildingNo|$roomNum';
          final id = '$effectiveImpl|$schoolAreaNo|$buildingNo|$roomNum';
          if (seen.contains(id) || id.contains('||')) continue;
          if (hasPhysicalKey && seenPhysical.contains(physicalKey)) {
            continue;
          }
          seen.add(id);
          if (hasPhysicalKey) seenPhysical.add(physicalKey);
          items.add(EcardRoomItem.fromJson({
            'id': id,
            'schoolArea': room['schoolArea'] ?? '',
            'building': room['building'] ?? '',
            'room': (room['room'] ?? '').replaceAll('#', '-'),
            'displayName':
                '${room['schoolArea'] ?? ''} ${room['building'] ?? ''} ${(room['room'] ?? room['roomNum'] ?? '').toString().replaceAll('#', '-')}'
                    .trim(),
          }));
        }
      } catch (exc) {
        errors.add(exc);
      }
    }
    if (items.isEmpty && errors.isNotEmpty) {
      throw ApiException('获取宿舍列表失败');
    }
    items.sort((a, b) => a.displayName.compareTo(b.displayName));
    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      return items
          .where((r) =>
              r.displayName.toLowerCase().contains(q) ||
              r.building.toLowerCase().contains(q) ||
              r.room.toLowerCase().contains(q) ||
              r.schoolArea.toLowerCase().contains(q))
          .take(limit)
          .toList();
    }
    return items.take(limit).toList();
  }

  Future<Map<String, dynamic>?> getBalance(String roomId,
      {String? studentId}) async {
    if (_token == null && !await login()) return null;
    final parts = roomId.split('|');
    if (parts.length != 4) return null;
    var r = await _post('powerfee/getBalance', {
      'implType': parts[0],
      'schoolAreaNo': parts[1],
      'buildingNo': parts[2],
      'roomNum': parts[3],
    });
    // Retry on auth failure (code=203 or "未登录")
    if (r['code'] == 203 || '${r['msg']}'.contains('未登录')) {
      _invalidateToken();
      if (!await login()) return null;
      r = await _post('powerfee/getBalance', {
        'implType': parts[0],
        'schoolAreaNo': parts[1],
        'buildingNo': parts[2],
        'roomNum': parts[3],
      });
    }
    if (r['ret'] != true && r['code'] != 200 && r['code'] != 0) return null;
    final obj = r['obj'] as Map<String, dynamic>?;
    if (obj == null) return null;

    // Hot water fallback: when /powerfee/getBalance doesn't include
    // hotWaterBalance, query /waterfee/memberInfo (personal hot-water account).
    // Mirrors backend EcardClient.balance() and edge function getHotWaterBalance().
    if (obj['hotWaterBalance'] == null &&
        studentId != null &&
        studentId.isNotEmpty) {
      try {
        final hotR = await _post('waterfee/memberInfo', {
          'sno': studentId,
          'implType': 'MINGHANBLUETOOTH',
        });
        if (hotR['ret'] == true || hotR['code'] == 200 || hotR['code'] == 0) {
          final hotObj = hotR['obj'];
          if (hotObj is Map) {
            final balance = hotObj['balance'];
            if (balance != null) {
              obj['hotWaterBalance'] = balance;
              obj['formatHotWaterBalanceStr'] = '$balance 元';
            }
          }
        }
      } catch (_) {
        // Hot water is a personal account; may not be activated. Silently skip.
      }
    }
    if (obj['hotWaterBalance'] != null &&
        obj['formatHotWaterBalanceStr'] == null &&
        obj['hotWaterText'] == null) {
      obj['formatHotWaterBalanceStr'] = '${obj['hotWaterBalance']} 元';
    }

    return obj;
  }

  bool _isEcardOk(Map<String, dynamic> data) =>
      data['ret'] == true ||
      data['code'] == 200 ||
      data['code'] == 0 ||
      data['resCode'] == 0 ||
      data['resCode'] == '0';
}

// Dart MD5 implementation
String _md5String(String input) {
  final data = _createBuffer(input);
  int a = 0x67452301, b = 0xEFCDAB89, c = 0x98BADCFE, d = 0x10325476;

  for (int i = 0; i < data.length; i += 16) {
    final aa = a, bb = b, cc = c, dd = d;
    a = _ff(a, b, c, d, data[i + 0], 7, 0xD76AA478);
    d = _ff(d, a, b, c, data[i + 1], 12, 0xE8C7B756);
    c = _ff(c, d, a, b, data[i + 2], 17, 0x242070DB);
    b = _ff(b, c, d, a, data[i + 3], 22, 0xC1BDCEEE);
    a = _ff(a, b, c, d, data[i + 4], 7, 0xF57C0FAF);
    d = _ff(d, a, b, c, data[i + 5], 12, 0x4787C62A);
    c = _ff(c, d, a, b, data[i + 6], 17, 0xA8304613);
    b = _ff(b, c, d, a, data[i + 7], 22, 0xFD469501);
    a = _ff(a, b, c, d, data[i + 8], 7, 0x698098D8);
    d = _ff(d, a, b, c, data[i + 9], 12, 0x8B44F7AF);
    c = _ff(c, d, a, b, data[i + 10], 17, 0xFFFF5BB1);
    b = _ff(b, c, d, a, data[i + 11], 22, 0x895CD7BE);
    a = _ff(a, b, c, d, data[i + 12], 7, 0x6B901122);
    d = _ff(d, a, b, c, data[i + 13], 12, 0xFD987193);
    c = _ff(c, d, a, b, data[i + 14], 17, 0xA679438E);
    b = _ff(b, c, d, a, data[i + 15], 22, 0x49B40821);
    a = _gg(a, b, c, d, data[i + 1], 5, 0xF61E2562);
    d = _gg(d, a, b, c, data[i + 6], 9, 0xC040B340);
    c = _gg(c, d, a, b, data[i + 11], 14, 0x265E5A51);
    b = _gg(b, c, d, a, data[i + 0], 20, 0xE9B6C7AA);
    a = _gg(a, b, c, d, data[i + 5], 5, 0xD62F105D);
    d = _gg(d, a, b, c, data[i + 10], 9, 0x02441453);
    c = _gg(c, d, a, b, data[i + 15], 14, 0xD8A1E681);
    b = _gg(b, c, d, a, data[i + 4], 20, 0xE7D3FBC8);
    a = _gg(a, b, c, d, data[i + 9], 5, 0x21E1CDE6);
    d = _gg(d, a, b, c, data[i + 14], 9, 0xC33707D6);
    c = _gg(c, d, a, b, data[i + 3], 14, 0xF4D50D87);
    b = _gg(b, c, d, a, data[i + 8], 20, 0x455A14ED);
    a = _gg(a, b, c, d, data[i + 13], 5, 0xA9E3E905);
    d = _gg(d, a, b, c, data[i + 2], 9, 0xFCEFA3F8);
    c = _gg(c, d, a, b, data[i + 7], 14, 0x676F02D9);
    b = _gg(b, c, d, a, data[i + 12], 20, 0x8D2A4C8A);
    a = _hh(a, b, c, d, data[i + 5], 4, 0xFFFA3942);
    d = _hh(d, a, b, c, data[i + 8], 11, 0x8771F681);
    c = _hh(c, d, a, b, data[i + 11], 16, 0x6D9D6122);
    b = _hh(b, c, d, a, data[i + 14], 23, 0xFDE5380C);
    a = _hh(a, b, c, d, data[i + 1], 4, 0xA4BEEA44);
    d = _hh(d, a, b, c, data[i + 4], 11, 0x4BDECFA9);
    c = _hh(c, d, a, b, data[i + 7], 16, 0xF6BB4B60);
    b = _hh(b, c, d, a, data[i + 10], 23, 0xBEBFBC70);
    a = _hh(a, b, c, d, data[i + 13], 4, 0x289B7EC6);
    d = _hh(d, a, b, c, data[i + 0], 11, 0xEAA127FA);
    c = _hh(c, d, a, b, data[i + 3], 16, 0xD4EF3085);
    b = _hh(b, c, d, a, data[i + 6], 23, 0x04881D05);
    a = _hh(a, b, c, d, data[i + 9], 4, 0xD9D4D039);
    d = _hh(d, a, b, c, data[i + 12], 11, 0xE6DB99E5);
    c = _hh(c, d, a, b, data[i + 15], 16, 0x1FA27CF8);
    b = _hh(b, c, d, a, data[i + 2], 23, 0xC4AC5665);
    a = _ii(a, b, c, d, data[i + 0], 6, 0xF4292244);
    d = _ii(d, a, b, c, data[i + 7], 10, 0x432AFF97);
    c = _ii(c, d, a, b, data[i + 14], 15, 0xAB9423A7);
    b = _ii(b, c, d, a, data[i + 5], 21, 0xFC93A039);
    a = _ii(a, b, c, d, data[i + 12], 6, 0x655B59C3);
    d = _ii(d, a, b, c, data[i + 3], 10, 0x8F0CCC92);
    c = _ii(c, d, a, b, data[i + 10], 15, 0xFFEFF47D);
    b = _ii(b, c, d, a, data[i + 1], 21, 0x85845DD1);
    a = _ii(a, b, c, d, data[i + 8], 6, 0x6FA87E4F);
    d = _ii(d, a, b, c, data[i + 15], 10, 0xFE2CE6E0);
    c = _ii(c, d, a, b, data[i + 6], 15, 0xA3014314);
    b = _ii(b, c, d, a, data[i + 13], 21, 0x4E0811A1);
    a = _ii(a, b, c, d, data[i + 4], 6, 0xF7537E82);
    d = _ii(d, a, b, c, data[i + 11], 10, 0xBD3AF235);
    c = _ii(c, d, a, b, data[i + 2], 15, 0x2AD7D2BB);
    b = _ii(b, c, d, a, data[i + 9], 21, 0xEB86D391);
    a = _add32(a, aa);
    b = _add32(b, bb);
    c = _add32(c, cc);
    d = _add32(d, dd);
  }
  return _hex(a) + _hex(b) + _hex(c) + _hex(d);
}

int _add32(int x, int y) => (x + y) & 0xFFFFFFFF;
int _cmn(int q, int a, int b, int x, int s, int t) =>
    _add32(_bitRol(_add32(_add32(a, q), _add32(x, t)), s), b);
int _ff(int a, int b, int c, int d, int x, int s, int t) =>
    _cmn((b & c) | ((~b) & d), a, b, x, s, t);
int _gg(int a, int b, int c, int d, int x, int s, int t) =>
    _cmn((b & d) | (c & (~d)), a, b, x, s, t);
int _hh(int a, int b, int c, int d, int x, int s, int t) =>
    _cmn(b ^ c ^ d, a, b, x, s, t);
int _ii(int a, int b, int c, int d, int x, int s, int t) =>
    _cmn(c ^ (b | (~d)), a, b, x, s, t);
int _bitRol(int num, int cnt) => (num << cnt) | (num >>> (32 - cnt));
String _hex(int n) {
  const h = '0123456789abcdef';
  return h[(n >> 4) & 15] +
      h[n & 15] +
      h[(n >> 12) & 15] +
      h[(n >> 8) & 15] +
      h[(n >> 20) & 15] +
      h[(n >> 16) & 15] +
      h[(n >> 28) & 15] +
      h[(n >> 24) & 15];
}

List<int> _createBuffer(String input) {
  final bytes = <int>[];
  for (int i = 0; i < input.length; i++) {
    final c = input.codeUnitAt(i);
    if (c < 128) {
      bytes.add(c);
    } else if (c < 2048) {
      bytes.add((c >> 6) | 192);
      bytes.add((c & 63) | 128);
    } else {
      bytes.add((c >> 12) | 224);
      bytes.add(((c >> 6) & 63) | 128);
      bytes.add((c & 63) | 128);
    }
  }
  final msgLen = bytes.length;
  bytes.add(128);
  while ((bytes.length % 64) != 56) {
    bytes.add(0);
  }
  final bitLen = msgLen * 8;
  for (int i = 0; i < 8; i++) {
    bytes.add((bitLen >> (i * 8)) & 255);
  }
  final data = <int>[];
  for (int i = 0; i < bytes.length; i += 4) {
    data.add(bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24));
  }
  return data;
}
