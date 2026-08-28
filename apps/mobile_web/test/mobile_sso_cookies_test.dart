import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/mobile_sso_cookies.dart';

void main() {
  test('解析有效 Cookie 并忽略无效片段', () {
    expect(
      parseCookieHeader(
          'JSESSIONID=ehall; Authorization=token=value; invalid; empty='),
      <String, String>{
        'JSESSIONID': 'ehall',
        'Authorization': 'token=value',
      },
    );
  });

  test('教务与办事大厅 Cookie 分别只写入对应域', () {
    expect(
      jwxtCookieDomains(Uri.parse('https://jwxt.gzus.edu.cn/jwglxt')),
      <String>['jwxt.gzus.edu.cn'],
    );
    expect(
      ehallCookieDomains(Uri.parse('https://ehall.gzus.edu.cn/bpm/r?x=1')),
      <String>['ehall.gzus.edu.cn'],
    );
    expect(isEhallHost('ehall.gzus.edu.cn'), isTrue);
    expect(isJwxtHost('jwxt.gzus.edu.cn'), isTrue);
  });

  test('外部域不接收学校 Cookie', () {
    expect(isGzusHost('example.com'), isFalse);
    expect(
      jwxtCookieDomains(Uri.parse('https://example.com/notice')),
      isEmpty,
    );
    expect(
      ehallCookieDomains(Uri.parse('https://example.com/notice')),
      isEmpty,
    );
  });
}
