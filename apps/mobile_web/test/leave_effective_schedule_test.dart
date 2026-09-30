import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/leave_attachment.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('请假预览和填表都会发送权威的空生效课表，填表错误传回页面', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['effectiveOccurrences'], isEmpty);
        expect(payload.containsKey('effectiveOccurrences'), isTrue);
        if (request.url.path == '/ehall/leave/preview') {
          return http.Response(
              jsonEncode(
                  {'status': 'ok', 'items': [], 'hasMissingFields': false}),
              200);
        }
        return http.Response.bytes(
            utf8.encode(jsonEncode({'detail': '该时间段没有匹配课程，请重新选择日期后再生成请假单'})),
            400,
            headers: {'content-type': 'application/json'});
      }),
    );
    final day = DateTime(2026, 9, 7);
    final preview = await api.previewLeave(
      year: 2026,
      term: 1,
      startDate: day,
      endDate: day,
      firstWeekStart: day,
      effectiveOccurrences: const [],
    );
    expect(preview.items, isEmpty);
    await expectLater(
      api.fillLeave(
        year: 2026,
        term: 1,
        startDate: day,
        endDate: day,
        firstWeekStart: day,
        reason: '事假',
        attachments: [
          PickedAttachment(name: 'note.jpg', bytes: Uint8List.fromList([1])),
        ],
        effectiveOccurrences: const [],
      ),
      throwsA(isA<ApiException>()
          .having((error) => error.statusCode, 'statusCode', 400)),
    );
    expect(requests, ['/ehall/leave/preview', '/ehall/leave/fill']);
  });
}
