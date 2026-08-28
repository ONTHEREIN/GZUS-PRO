import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/widgets/async_panel.dart';

void main() {
  testWidgets('有首页缓存时首屏直接展示缓存数据', (tester) async {
    final completer = Completer<String>();

    await tester.pumpWidget(
      MaterialApp(
        home: AsyncPanel<String>(
          future: completer.future,
          initialData: '首页缓存',
          builder: (data) => Text(data),
        ),
      ),
    );

    expect(find.text('首页缓存'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    completer.complete('最新数据');
    await tester.pumpAndSettle();
    expect(find.text('最新数据'), findsOneWidget);
  });

  testWidgets('下拉刷新失败时显示具体错误原因', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageRefresh(
            onRefresh: () async {
              throw ApiException('学校教务系统响应超时（已自动重试），请稍后再试', statusCode: 502);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 800)],
            ),
          ),
        ),
      ),
    );

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('刷新失败：学校系统请求异常：学校教务系统响应超时（已自动重试），请稍后再试'),
      findsOneWidget,
    );
  });
}
