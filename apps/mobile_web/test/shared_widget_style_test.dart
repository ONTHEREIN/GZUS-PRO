import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/widgets/badges.dart';
import 'package:gzus_pro_mobile_web/widgets/info_tile.dart';
import 'package:gzus_pro_mobile_web/widgets/page_panel.dart';

void main() {
  testWidgets('共享信息组件在紧凑和宽屏下不使用模糊表面', (tester) async {
    addTearDown(tester.view.reset);
    for (final size in const [Size(320, 640), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: gzusTheme(Brightness.light),
          home: const Scaffold(
            body: PagePanel(
              title: '课程概览',
              icon: Icons.calendar_today_outlined,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  InfoTile(
                    label: '下一节课',
                    value: '数据结构',
                    icon: Icons.school_outlined,
                  ),
                  MetricPill(
                    icon: Icons.schedule_outlined,
                    label: '时间',
                    value: '10:10',
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('深色模式的信息层级保持可渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.dark),
        home: const Scaffold(
          body: Center(
            child: MetricPill(
              icon: Icons.place_outlined,
              label: '地点',
              value: 'A301',
            ),
          ),
        ),
      ),
    );

    expect(find.text('地点'), findsOneWidget);
    expect(find.text('A301'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
