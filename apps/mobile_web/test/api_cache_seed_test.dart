import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/persistent_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('dashboard 种子缓存后详情页不再发重复请求', () async {
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
              'me': {
                'status': 'ok',
                'data': {
                  'studentId': '20260001',
                  'name': '测试同学',
                },
              },
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
              'attendance': {
                'status': 'ok',
                'data': {
                  'status': 'ok',
                  'items': [
                    {
                      'courseId': 'course-a',
                      'courseName': '课程A',
                      'normal': 2,
                    }
                  ],
                },
              },
              'credits': {
                'status': 'ok',
                'data': [
                  {
                    'name': '测试同学',
                    'totalCredit': '120',
                  }
                ],
              },
              'notices': {
                'status': 'ok',
                'data': [
                  {
                    'title': '测试通知',
                    'url': 'https://example.test/notices/1',
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
    final info = await api.me();
    await api.schedule(year: 2025, term: 2);
    final attendance = await api.attendance(year: 2025, term: 2);
    final credits = await api.credits();
    final notices = await api.notices();

    expect(requests, ['/dashboard?year=2025&term=2&week=3'],
        reason: '详情页应命中 dashboard 种子缓存');
    expect(info.data.name, '测试同学');
    expect(attendance.data.items.single.courseName, '课程A');
    expect(credits.data.single.totalCredit, '120');
    expect(notices.data.single.title, '测试通知');

    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('pcache_default_notices')!),
      contains(
        isA<Map<String, dynamic>>().having(
          (item) => item['title'],
          'title',
          '测试通知',
        ),
      ),
    );
  });

  test('缺少课程标识的 dashboard 考勤不会阻塞明细查询', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requests.add('${request.url.path}?${request.url.query}');
        if (request.url.path == '/dashboard') {
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'modules': {
                'attendance': {
                  'status': 'ok',
                  'data': {
                    'status': 'ok',
                    'items': [
                      {'courseName': '旧缓存课程', 'normal': 1},
                    ],
                  },
                },
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'status': 'ok',
            'items': [
              {
                'courseId': 'course-1',
                'courseName': '新课程',
                'normal': 1,
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    await api.dashboard(year: 2025, term: 2, week: 3);
    final attendance = await api.attendance(year: 2025, term: 2);

    expect(
      requests,
      [
        '/dashboard?year=2025&term=2&week=3',
        '/attendance?year=2025&term=2',
      ],
    );
    expect(attendance.data.items.single.courseId, 'course-1');
  });

  test('会话命名空间缓存迁移后可按学号读取考试缓存', () async {
    SharedPreferences.setMockInitialValues({
      'pcache_session-1_exams_2025_1': jsonEncode([
        {
          'courseName': '缓存考试',
          'time': '2026-06-20 09:00',
          'location': 'A101',
        }
      ]),
      'pcache_session-1_exams_2025_1_at': '2026-06-01T00:00:00.000',
    });
    await PersistentCache.migrateNamespace(
      fromNamespace: 'session-1',
      toNamespace: '20240001',
    );
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        fail('命中迁移后的本地缓存时不应发起请求');
      }),
    );
    api.useSession('session-1');
    api.setStudentId('20240001');

    final result = await api.exams(year: 2025, term: 1);
    final prefs = await SharedPreferences.getInstance();

    expect(result.data.single.courseName, '缓存考试');
    expect(result.source.fromLocalCache, isTrue);
    expect(prefs.containsKey('pcache_session-1_exams_2025_1'), isFalse);
  });

  test('认证响应立即采用学号作为缓存命名空间', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'status': 'ok',
              'sessionId': 'session-2',
              'studentName': '测试同学',
              'studentId': '20240002',
            })),
            200,
          )),
    );

    await api.completeLySso('sso-code');

    expect(api.namespace, '20240002');
  });

  test('考试服务端缓存响应会保留来源信息', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode([
              {
                'courseName': '服务端缓存考试',
                'time': '2026-06-20 09:00',
                'location': 'A101',
              }
            ])),
            200,
            headers: {
              'x-data-source': 'cache',
              'x-data-cached-at': '2026-06-01T00:00:00.000Z',
            },
          )),
    );

    final result = await api.exams(year: 2025, term: 1, forceRefresh: true);

    expect(result.source.fromCache, isTrue);
    expect(result.source.displayText, contains('服务端缓存'));
  });

  test('空列表和不完整个人信息不会写入本地缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/notices') {
          return http.Response('[]', 200);
        }
        return http.Response(
          jsonEncode({'studentId': '20240001', 'name': ''}),
          200,
        );
      }),
    );

    final notices = await api.notices();
    expect(notices.data, isEmpty);
    await expectLater(api.me(), throwsA(isA<ApiException>()));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('pcache_default_notices'), isFalse);
    expect(prefs.containsKey('pcache_default_me'), isFalse);
  });

  test('通知强制刷新绕过本地缓存并保留来源信息', () async {
    SharedPreferences.setMockInitialValues({
      'pcache_default_notices': jsonEncode([
        {'title': '旧通知', 'category': '通知'}
      ]),
      'pcache_default_notices_at': DateTime(2026, 6, 1).toIso8601String(),
    });
    final requests = <String>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requests.add('${request.url.path}?${request.url.query}');
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'title': '2026-2027 学年校历',
              'category': '校历',
              'source': 'admin',
            }
          ])),
          200,
        );
      }),
    );

    final notices = await api.notices(forceRefresh: true);

    expect(requests, ['/notices?refresh=true']);
    expect(notices.data.single.title, '2026-2027 学年校历');
    expect(notices.data.single.source, NoticeSource.admin);
  });

  test('登录轮播图使用独立公共本地缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final firstApi = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/content/login-slides');
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'id': 1,
              'title': '欢迎使用',
              'imageUrl': '/admin/login-slides/1/image',
              'published': true,
              'sortOrder': 1,
            }
          ])),
          200,
        );
      }),
    );

    final fetched = await firstApi.loginCarouselSlides();
    expect(fetched.single.title, '欢迎使用');

    final secondApi = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        return http.Response.bytes(utf8.encode('服务不可用'), 503);
      }),
    );
    final cached = await secondApi.loginCarouselSlides();
    final prefs = await SharedPreferences.getInstance();

    expect(cached.single.imageUrl, '/admin/login-slides/1/image');
    expect(prefs.containsKey('pcache_public_login_slides'), isTrue);
  });
}
