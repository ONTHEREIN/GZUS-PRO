import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/notices/notices_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('紧凑布局先展示应用内通知详情再提供原网页入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/notices') {
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {
                'category': '通知公告',
                'title': '课程调整通知',
                'date': '2026-08-29',
                'url': 'https://jwxt.example.test/notice/1.html',
                'source': 'jwxt',
              }
            ])),
            200,
          );
        }
        if (request.url.path == '/notices/detail') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'title': '课程调整通知',
              'date': '2026-08-29',
              'contentHtml': '<p>这是应用抓取的详情正文。</p><p>&nbsp;</p><p>第二段正文。</p>',
              'url': 'https://jwxt.example.test/notice/1.html',
            })),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 844,
              child: NoticesPage(api: api),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey('notice-card-https://jwxt.example.test/notice/1.html'),
      ),
    );
    await tester.pumpAndSettle();

    final content = tester.widget<Text>(
      find.byKey(const ValueKey('notice-detail-content')),
    );
    expect(content.data, '这是应用抓取的详情正文。\n第二段正文。');
    expect(find.byKey(const ValueKey('notice-open-original')), findsOneWidget);
  });
}
