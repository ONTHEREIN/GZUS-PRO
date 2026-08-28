import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/native_sso.dart';

void main() {
  test('生成的原生 SSO verifier 使用 URL 安全字符且长度足够', () {
    final verifier = createNativeSsoVerifier();

    expect(verifier.length, greaterThanOrEqualTo(32));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(verifier), isTrue);
  });

  test('从受信任的原生 SSO 回调中提取 code', () {
    final code = nativeSsoCodeFromCallback(
      'cn.gzus.pro://sso/callback?code=one-time-code',
    );

    expect(code, 'one-time-code');
  });

  test('拒绝错误来源或缺少 code 的原生 SSO 回调', () {
    expect(
      () => nativeSsoCodeFromCallback('cn.gzus.pro://other/callback?code=code'),
      throwsFormatException,
    );
    expect(
      () => nativeSsoCodeFromCallback('cn.gzus.pro://sso/callback'),
      throwsFormatException,
    );
  });
}
