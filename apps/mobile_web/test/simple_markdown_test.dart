import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/widgets/simple_markdown.dart';

void main() {
  Future<void> pump(WidgetTester tester, String source) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SimpleMarkdown(source))),
      );

  testWidgets('表格渲染为 Table，分隔行不出现，加粗去掉星号', (tester) async {
    await pump(tester,
        '上学期成绩：\n\n| 课程 | 成绩 |\n|---|---|\n| **数据结构** | 89 |\n| 操作系统 | 85 |');
    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('|'), findsNothing);
    expect(find.textContaining('---'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('数据结构', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无序与有序列表显示圆点和序号', (tester) async {
    await pump(tester, '- 电费：**68.4 度**\n- 冷水：9.6 吨\n1. 看通知\n2. 问辅导员');
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('未闭合的标记与普通竖线按原文显示', (tester) async {
    await pump(tester, '比例 3 | 4，**未闭合');
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('**未闭合', findRichText: true), findsOneWidget);
  });
}
