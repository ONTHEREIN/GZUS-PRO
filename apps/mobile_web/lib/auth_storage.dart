import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SensitiveAuthState {
  const SensitiveAuthState({
    required this.credentialToken,
    required this.jwxtCookies,
    required this.ehallCookies,
    required this.ehallAuthToken,
  });

  final String? credentialToken;
  final String? jwxtCookies;
  final String? ehallCookies;
  final String? ehallAuthToken;
}

class AuthStorage {
  const AuthStorage();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _credentialTokenKey = 'auth.credentialToken';
  static const String _jwxtCookiesKey = 'auth.jwxtCookies';
  static const String _ehallCookiesKey = 'auth.ehallCookies';
  static const String _ehallAuthTokenKey = 'auth.ehallAuthToken';

  Future<void> saveCredentialToken(String credentialToken) async {
    if (credentialToken.isEmpty) {
      throw ArgumentError.value(
        credentialToken,
        'credentialToken',
        '自动登录凭据不能为空',
      );
    }
    await _secureStorage.write(
      key: _credentialTokenKey,
      value: credentialToken,
    );
    await _removeLegacyValues([_credentialTokenKey]);
  }

  Future<void> clearCredentialToken() async {
    await _secureStorage.delete(key: _credentialTokenKey);
    await _removeLegacyValues([_credentialTokenKey]);
  }

  Future<void> saveSchoolAuth(
    String? jwxtCookies,
    String? ehallCookies,
    String? ehallAuthToken,
  ) async {
    await _writeOptional(_jwxtCookiesKey, jwxtCookies);
    await _writeOptional(_ehallCookiesKey, ehallCookies);
    await _writeOptional(_ehallAuthTokenKey, ehallAuthToken);
    await _removeLegacyValues([
      _jwxtCookiesKey,
      _ehallCookiesKey,
      _ehallAuthTokenKey,
    ]);
  }

  Future<SensitiveAuthState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final credentialToken = await _readAndMigrate(
      prefs,
      _credentialTokenKey,
    );
    final jwxtCookies = await _readAndMigrate(prefs, _jwxtCookiesKey);
    final ehallCookies = await _readAndMigrate(prefs, _ehallCookiesKey);
    final ehallAuthToken = await _readAndMigrate(
      prefs,
      _ehallAuthTokenKey,
    );
    return SensitiveAuthState(
      credentialToken: credentialToken,
      jwxtCookies: jwxtCookies,
      ehallCookies: ehallCookies,
      ehallAuthToken: ehallAuthToken,
    );
  }

  Future<void> clear() async {
    for (final key in [
      _credentialTokenKey,
      _jwxtCookiesKey,
      _ehallCookiesKey,
      _ehallAuthTokenKey,
    ]) {
      await _secureStorage.delete(key: key);
    }
    await _removeLegacyValues([
      _credentialTokenKey,
      _jwxtCookiesKey,
      _ehallCookiesKey,
      _ehallAuthTokenKey,
    ]);
  }

  Future<void> _writeOptional(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secureStorage.delete(key: key);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }

  Future<String?> _readAndMigrate(
    SharedPreferences prefs,
    String key,
  ) async {
    final secureValue = await _secureStorage.read(key: key);
    if (secureValue != null && secureValue.isNotEmpty) {
      await prefs.remove(key);
      return secureValue;
    }

    final legacyValue = prefs.getString(key);
    if (legacyValue == null || legacyValue.isEmpty) {
      await prefs.remove(key);
      return null;
    }
    await _secureStorage.write(key: key, value: legacyValue);
    await prefs.remove(key);
    return legacyValue;
  }

  Future<void> _removeLegacyValues(List<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}
