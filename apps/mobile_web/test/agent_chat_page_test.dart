import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/agent/agent_chat_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('智能助手发送问题后展示回答与可展开的执行链路', (tester) async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/agent/chat'));
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'conversationId': 'c1',
          'turn': 1,
          'status': 'ok',
          'answer': '宿舍电费还剩 68.4 度。',
          'latencyMs': 2266.3,
          'spans': [
            {'span': 'plan', 'intent': '查电费', 'steps': ['get_card_balance'], 'latency_ms': 1200},
            {'span': 'tool_call', 'name': 'get_card_balance', 'args': {}, 'schema_ok': true},
            {'span': 'observation', 'ok': true, 'row_count': null},
            {'span': 'generate', 'latency_ms': 1000},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = ApiClient(httpClient: client, baseUrl: 'https://api.example.test');

    await tester.pumpWidget(MaterialApp(home: AgentChatPage(api: api)));
    await tester.tap(find.text('宿舍还剩多少电'));
    await tester.pumpAndSettle();

    expect(requests.single['messages'], [
      {'role': 'user', 'content': '宿舍还剩多少电'},
    ]);
    expect(find.text('宿舍电费还剩 68.4 度。'), findsOneWidget);
    expect(find.text('执行链路 · 4 步 · 2.3s'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-chat-trace')));
    await tester.pumpAndSettle();
    expect(find.text('规划：查电费（get_card_balance）'), findsOneWidget);
    expect(find.text('调用 get_card_balance()'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
