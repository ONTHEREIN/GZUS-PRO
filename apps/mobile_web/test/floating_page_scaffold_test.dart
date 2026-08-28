import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/widgets/floating_page_scaffold.dart';

void main() {
  testWidgets('悬浮页面标题在不同宽度下连续过渡', (tester) async {
    addTearDown(tester.view.reset);
    for (final size in const <Size>[
      Size(390, 844),
      Size(840, 900),
      Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_testApp(key: ValueKey<double>(size.width)));

      final glass = find.byKey(const ValueKey('page-panel-glass-surface'));
      final list = find.byType(ListView);
      expect(_glassOpacity(tester, glass), 0);
      expect(find.text('测试标题'), findsOneWidget);

      await tester.drag(list, const Offset(0, -36));
      await tester.pumpAndSettle();
      expect(_glassOpacity(tester, glass), closeTo(0.5, 0.08));

      await tester.drag(list, const Offset(0, -96));
      await tester.pumpAndSettle();
      expect(_glassOpacity(tester, glass), 1);
      expect(tester.takeException(), isNull);
    }
  });
}

Widget _testApp({required Key key}) {
  return MaterialApp(
    home: FloatingPageScaffold(
      key: key,
      title: '测试标题',
      icon: Icons.science_outlined,
      actions: const <Widget>[],
      bottom: null,
      floatingActionButton: null,
      body: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: 24,
        itemBuilder: (context, index) => ListTile(title: Text('条目 $index')),
      ),
    ),
  );
}

double _glassOpacity(WidgetTester tester, Finder glass) {
  final opacity =
      find.ancestor(of: glass, matching: find.byType(Opacity)).first;
  return tester.widget<Opacity>(opacity).opacity;
}
