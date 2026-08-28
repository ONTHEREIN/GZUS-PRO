import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/auth_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('保存并恢复教务与办事大厅登录态', () async {
    const storage = AuthStorage();

    await storage.saveSchoolAuth(
      'jwxt-cookie',
      'ehall-cookie',
      'ehall-token',
    );
    final restored = await storage.load();

    expect(restored.jwxtCookies, 'jwxt-cookie');
    expect(restored.ehallCookies, 'ehall-cookie');
    expect(restored.ehallAuthToken, 'ehall-token');
    expect(restored.credentialToken, isNull);
  });

  test('清除登录态同时移除教务 Cookie', () async {
    const storage = AuthStorage();
    await storage.saveSchoolAuth('jwxt-cookie', 'ehall-cookie', 'ehall-token');

    await storage.clear();
    final restored = await storage.load();

    expect(restored.jwxtCookies, isNull);
    expect(restored.ehallCookies, isNull);
    expect(restored.ehallAuthToken, isNull);
  });
}
