import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/models/schedule_override.dart';
import 'package:gzus_pro_mobile_web/schedule_adjustment_sync.dart';
import 'package:gzus_pro_mobile_web/pages/schedule/schedule_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

ScheduleAdjustmentRecord _adjustment(String id, String status, int revision) =>
    ScheduleAdjustmentRecord(
      clientId: id,
      year: 2026,
      term: 1,
      sourceDate: DateTime(2026, 9, 7),
      targetDate: DateTime(2026, 9, 8),
      sourceOccurrenceKeys: const [],
      targetConflictKeys: const [],
      conflictMode: 'coexist',
      status: status,
      revision: revision,
    );

ApiClient _api(String account, MockClient client) =>
    ApiClient(baseUrl: 'https://api.example.test', httpClient: client)
      ..sessionId = 'session-$account'
      ..setStudentId(account);

http.Response _response(ScheduleAdjustmentRecord record) =>
    http.Response(jsonEncode(record.toJson()), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const widgetChannel = MethodChannel('cn.gzus.pro/home_widgets');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(widgetChannel, (call) async => null);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(widgetChannel, null));

  test('引导读取云端调课时仍保留本机待同步撤回和新增记录', () async {
    final api = _api('A', MockClient((request) async {
      return http.Response(
          jsonEncode([_adjustment('remote', 'active', 1).toJson()]), 200);
    }));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('remote', 'restored', 2));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('local', 'active', 1));
    final records =
        await ScheduleAdjustmentSync.loadCurrent(api: api, year: 2026, term: 1);
    expect(records.map((item) => item.clientId), ['remote', 'local']);
    expect(records.first.status, 'restored');
  });

  test('读取调课期间切换账号时拒绝使用前一个账号的结果', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final api = _api('A', MockClient((request) async {
      started.complete();
      await release.future;
      return http.Response(
          jsonEncode([_adjustment('A-record', 'active', 1).toJson()]), 200);
    }));
    final loading =
        ScheduleAdjustmentSync.loadCurrent(api: api, year: 2026, term: 1);
    final expectation = expectLater(loading, throwsA(isA<StateError>()));
    await started.future;
    api.setStudentId('B');
    release.complete();
    await expectation;
  });

  test('账号 B 不显示或上传账号 A 的本地调课，旧版无归属记录保持原样', () async {
    final legacy = jsonEncode([_adjustment('legacy', 'active', 1).toJson()]);
    SharedPreferences.setMockInitialValues({
      'schedule.adjustmentQueue.2026.1': legacy,
    });
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('A-only', 'active', 1));
    await ScheduleOverrideStore.save('A', 2026, 1, const [
      ScheduleOverride(id: 'A-hide', matchKey: 'name:数学', hidden: true),
    ]);
    final api = _api('B', MockClient((request) async {
      fail('账号 B 不应发起账号 A 的调课上传');
    }));

    await ScheduleAdjustmentSync.flush(api: api, year: 2026, term: 1);

    expect(await ScheduleAdjustmentSync.loadQueue('B', 2026, 1), isEmpty);
    expect(await ScheduleOverrideStore.load('B', 2026, 1), isEmpty);
    expect(
        (await ScheduleAdjustmentSync.loadQueue('A', 2026, 1)).single.clientId,
        'A-only');
    expect(
        (await ScheduleOverrideStore.load('A', 2026, 1)).single.id, 'A-hide');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule.adjustmentQueue.2026.1'), legacy);
  });

  test('上传期间撤回和新增的记录不会被旧上传结果删除，并继续同步到云端', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var firstRequest = true;
    final submitted = <String>[];
    final api = _api('A', MockClient((request) async {
      if (firstRequest) {
        firstRequest = false;
        started.complete();
        await release.future;
        return _response(_adjustment('first', 'active', 1));
      }
      if (request.url.path.endsWith('/restore')) {
        submitted.add('restore-first');
        expect(request.url.queryParameters['expectedRevision'], '1');
        return _response(_adjustment('first', 'restored', 2));
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      submitted.add(body['clientId'] as String);
      return _response(_adjustment(body['clientId'] as String, 'active', 1));
    }));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('first', 'active', 1));
    final uploading =
        ScheduleAdjustmentSync.flush(api: api, year: 2026, term: 1);
    await started.future;
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('first', 'restored', 2));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('second', 'active', 1));
    release.complete();
    await uploading;

    expect(submitted, ['first', 'restore-first', 'second']);
    expect(await ScheduleAdjustmentSync.loadQueue('A', 2026, 1), isEmpty);
    final snapshot = await ScheduleAdjustmentSync.loadSnapshot('A', 2026, 1);
    expect(snapshot.map((item) => item.clientId), ['first', 'second']);
    expect(snapshot.first.status, 'restored');
    expect(await ScheduleAdjustmentSync.loadSnapshot('B', 2026, 1), isEmpty);
  });

  test('明确确认旧版记录归属后，只导入选定账号且可安全重复调用', () async {
    const override =
        ScheduleOverride(id: 'legacy-hide', matchKey: 'name:数学', hidden: true);
    SharedPreferences.setMockInitialValues({
      'schedule.adjustmentQueue.2026.1':
          jsonEncode([_adjustment('legacy', 'active', 1).toJson()]),
      'schedule.localOverrides.2026.1': jsonEncode([override.toJson()]),
    });
    await ScheduleAdjustmentSync.importLegacyQueue('A', 2026, 1);
    await ScheduleOverrideStore.importLegacyOverrides('A', 2026, 1);
    await ScheduleAdjustmentSync.importLegacyQueue('A', 2026, 1);
    await ScheduleOverrideStore.importLegacyOverrides('A', 2026, 1);

    expect(await ScheduleAdjustmentSync.loadQueue('A', 2026, 1), hasLength(1));
    expect(await ScheduleOverrideStore.load('A', 2026, 1), hasLength(1));
    expect(await ScheduleAdjustmentSync.loadQueue('B', 2026, 1), isEmpty);
    expect(await ScheduleOverrideStore.load('B', 2026, 1), isEmpty);
    expect(await ScheduleAdjustmentSync.hasLegacyQueue(2026, 1), isFalse);
    expect(await ScheduleOverrideStore.hasLegacyOverrides(2026, 1), isFalse);
  });

  test('旧版与当前账号同编号记录不同时明确拒绝导入，双方记录不被覆盖', () async {
    final legacy = jsonEncode([_adjustment('same', 'active', 1).toJson()]);
    SharedPreferences.setMockInitialValues(
        {'schedule.adjustmentQueue.2026.1': legacy});
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('same', 'restored', 2));
    await expectLater(ScheduleAdjustmentSync.importLegacyQueue('A', 2026, 1),
        throwsStateError);
    expect((await ScheduleAdjustmentSync.loadQueue('A', 2026, 1)).single.status,
        'restored');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule.adjustmentQueue.2026.1'), legacy);
  });

  test('上传失败明确抛错，仅确认之前成功的记录，未完成记录留在本机', () async {
    final api = _api('A', MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['clientId'] == 'bad') {
        return http.Response('{"detail":"调课日期无效"}', 422,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return _response(_adjustment('good', 'active', 1));
    }));
    await ScheduleAdjustmentSync.enqueue('A', _adjustment('good', 'active', 1));
    await ScheduleAdjustmentSync.enqueue('A', _adjustment('bad', 'active', 1));

    await expectLater(
      ScheduleAdjustmentSync.flush(api: api, year: 2026, term: 1),
      throwsA(isA<ApiException>()),
    );
    expect(
        (await ScheduleAdjustmentSync.loadQueue('A', 2026, 1)).single.clientId,
        'bad');
    expect(
        (await ScheduleAdjustmentSync.loadSnapshot('A', 2026, 1))
            .single
            .clientId,
        'good');
  });

  test('离线撤回按原修订号提交，不覆盖其他设备的新修订', () async {
    final api = _api('A', MockClient((request) async {
      if (request.url.path.endsWith('/restore')) {
        expect(request.url.queryParameters['expectedRevision'], '1');
        return http.Response('{"detail":"记录已被其他设备修改"}', 409,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return _response(_adjustment('changed', 'active', 3));
    }));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('changed', 'restored', 2));

    await expectLater(
      ScheduleAdjustmentSync.flush(api: api, year: 2026, term: 1),
      throwsA(isA<ScheduleAdjustmentConflict>()),
    );
    expect(
        (await ScheduleAdjustmentSync.loadQueue('A', 2026, 1)).single.revision,
        2);
    await ScheduleAdjustmentSync.discardPending(
        'A', _adjustment('changed', 'restored', 2));
    expect(await ScheduleAdjustmentSync.loadQueue('A', 2026, 1), isEmpty);
  });

  test('失败重试前账号切换会终止上传，原账号队列仍保留', () async {
    late ApiClient api;
    var requests = 0;
    api = _api('A', MockClient((request) async {
      requests++;
      expect(request.headers['X-Session-Id'], 'session-A');
      api.setStudentId('B');
      api.sessionId = 'session-B';
      return http.Response('{"detail":"暂时不可用"}', 503,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    await ScheduleAdjustmentSync.enqueue(
        'A', _adjustment('first', 'active', 1));

    await expectLater(
      ScheduleAdjustmentSync.flush(api: api, year: 2026, term: 1),
      throwsA(isA<ApiException>()),
    );
    expect(requests, 1);
    expect(await ScheduleAdjustmentSync.loadQueue('A', 2026, 1), hasLength(1));
    expect(await ScheduleAdjustmentSync.loadQueue('B', 2026, 1), isEmpty);
  });

  test('离线撤回覆盖云端快照后，生效课表和请假课程回到原日期', () {
    final adjustments = mergePendingScheduleAdjustments(
      [_adjustment('first', 'active', 1)],
      [_adjustment('first', 'restored', 2)],
    );
    final courses = expandEffectiveSchedule(
      courses: [
        ScheduleCourse(name: '数学', weekday: 1, startSection: 1, weeks: '1'),
      ],
      firstWeekStart: DateTime(2026, 9, 7),
      adjustments: adjustments,
    );
    expect(courses.single.date, DateTime(2026, 9, 7));
  });

  testWidgets('窄屏旧版调课导入必须确认账号归属，取消会保留原记录', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(widgetChannel, (call) async {
      throw PlatformException(
          code: 'WIDGET_NOT_CONFIGURED', message: '请先返回首页刷新');
    });
    SharedPreferences.setMockInitialValues(
        {'schedule.adjustmentQueue.2026.1': '[]'});
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _api('A', MockClient((request) async {
      final path = request.url.path;
      return http.Response(
          path == '/schedule' || path == '/settings/schedule/adjustments'
              ? '[]'
              : '{}',
          200);
    }));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.5)),
        child: child!,
      ),
      home: Scaffold(
          body: SchedulePage(
        api: api,
        year: 2026,
        term: 1,
        currentWeek: 1,
        firstWeekStart: DateTime(2026, 9, 7),
        autoWeek: true,
        onFirstWeekChanged: (_) {},
        onCurrentWeekChanged: (_) {},
        onAutoWeekChanged: (_) {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-widget-sync-error')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-legacy-import')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('schedule-legacy-import-cancel')));
    await tester.pumpAndSettle();
    expect(await ScheduleAdjustmentSync.hasLegacyQueue(2026, 1), isTrue);
    await tester.tap(find.byKey(const ValueKey('schedule-legacy-import')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('schedule-legacy-import-confirm')));
    await tester.pumpAndSettle();
    expect(await ScheduleAdjustmentSync.hasLegacyQueue(2026, 1), isFalse);
    expect(tester.takeException(), isNull);
  });
}
