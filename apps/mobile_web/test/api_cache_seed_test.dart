import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('dashboard 种子缓存后 schedule 不再发网络请求', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requests.add('${request.url.path}?${request.url.query}');
        final path = request.url.path;
        Object body;
        if (path == '/dashboard') {
          body = {
            'status': 'ok',
            'generatedAt': '2026-06-29T00:00:00Z',
            'modules': {
              'schedule': {
                'status': 'ok',
                'data': [
                  {
                    'name': '课程A',
                    'weekday': 1,
                    'startSection': 1,
                    'endSection': 2,
                    'weeks': '1-16',
                  }
                ],
              },
            },
          };
        } else {
          body = {'status': 'ok', 'data': <Object>[]};
        }
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
      }),
    );

    await api.dashboard(year: 2025, term: 2, week: 3);
    await api.schedule(year: 2025, term: 2);

    expect(requests, ['/dashboard?year=2025&term=2&week=3'],
        reason: 'schedule 应命中 dashboard 种子缓存');
  });
}
