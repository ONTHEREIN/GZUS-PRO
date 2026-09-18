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
    expect(restored.password, isNull);
  });

  test('清除登录态同时移除教务 Cookie', () async {
    const storage = AuthStorage();
    await storage.saveSchoolAuth('jwxt-cookie', 'ehall-cookie', 'ehall-token');
    await storage.savePassword('school-password');

    await storage.clear();
    final restored = await storage.load();

    expect(restored.jwxtCookies, isNull);
    expect(restored.ehallCookies, isNull);
    expect(restored.ehallAuthToken, isNull);
    expect(restored.password, isNull);
  });

  test('密码仅保存到系统安全存储', () async {
    const storage = AuthStorage();

    await storage.savePassword('school-password');
    final restored = await storage.load();
    final prefs = await SharedPreferences.getInstance();
    const secureStorage = FlutterSecureStorage();

    expect(restored.password, 'school-password');
    expect(prefs.getString('auth.password'), isNull);
    expect(
      await secureStorage.read(key: 'auth.password'),
      'school-password',
    );
  });
}
