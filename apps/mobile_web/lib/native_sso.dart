import 'dart:convert';
import 'dart:math';

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

const nativeSsoCallbackScheme = 'cn.gzus.pro';
const _nativeSsoCallbackHost = 'sso';
const _nativeSsoCallbackPath = '/callback';

String createNativeSsoVerifier() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Future<String> authenticateNativeSso(String authorizationUrl) {
  return FlutterWebAuth2.authenticate(
    url: authorizationUrl,
    callbackUrlScheme: nativeSsoCallbackScheme,
  );
}

String nativeSsoCodeFromCallback(String callbackUrl) {
  final uri = Uri.tryParse(callbackUrl);
  if (uri == null ||
      uri.scheme != nativeSsoCallbackScheme ||
      uri.host != _nativeSsoCallbackHost ||
      uri.path != _nativeSsoCallbackPath) {
    throw const FormatException('统一身份认证回调地址无效');
  }
  final code = uri.queryParameters['code'];
  if (code == null || code.isEmpty) {
    throw const FormatException('统一身份认证回调缺少凭证');
  }
  return code;
}
