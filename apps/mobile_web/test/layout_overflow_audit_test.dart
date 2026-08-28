import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/live_activity_service.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/models/nav_config.dart';
import 'package:gzus_pro_mobile_web/pages/more/more_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AuditViewport {
  const _AuditViewport({
    required this.name,
    required this.size,
    required this.textScale,
  });

  final String name;
  final Size size;
  final double textScale;
}

const _standardAuditViewports = [
  _AuditViewport(name: '320x568@1.0', size: Size(320, 568), textScale: 1),
  _AuditViewport(name: '320x568@1.3', size: Size(320, 568), textScale: 1.3),
  _AuditViewport(name: '390x844@1.0', size: Size(390, 844), textScale: 1),
  _AuditViewport(name: '390x844@1.3', size: Size(390, 844), textScale: 1.3),
  _AuditViewport(name: '844x390@1.0', size: Size(844, 390), textScale: 1),
  _AuditViewport(name: '844x390@1.3', size: Size(844, 390), textScale: 1.3),
  _AuditViewport(name: '720x1024@1.0', size: Size(720, 1024), textScale: 1),
  _AuditViewport(name: '720x1024@1.3', size: Size(720, 1024), textScale: 1.3),
  _AuditViewport(name: '1280x800@1.0', size: Size(1280, 800), textScale: 1),
  _AuditViewport(name: '1280x800@1.3', size: Size(1280, 800), textScale: 1.3),
];

const _largeTextAuditViewports = [
  _AuditViewport(name: '320x568@1.5', size: Size(320, 568), textScale: 1.5),
  _AuditViewport(name: '390x844@1.5', size: Size(390, 844), textScale: 1.5),
  _AuditViewport(name: '844x390@1.5', size: Size(844, 390), textScale: 1.5),
];

void main() {
  for (final viewport in _standardAuditViewports) {
    testWidgets('全导航页在 ${viewport.name} 无布局溢出', (tester) async {
      final findings = <String>[];
      await _pumpDashboard(
        tester: tester,
        viewport: viewport,
        findings: findings,
      );
      await _auditAllNavigationTabs(
        tester: tester,
        viewport: viewport,
        findings: findings,
      );
      _expectNoLayoutFindings(findings: findings, viewport: viewport);
    });
  }

  for (final viewport in _largeTextAuditViewports) {
    testWidgets('高风险页面在 ${viewport.name} 无布局溢出', (tester) async {
      final findings = <String>[];
      await _pumpDashboard(
        tester: tester,
        viewport: viewport,
        findings: findings,
      );
      await _auditHighRiskTabs(
        tester: tester,
        viewport: viewport,
        findings: findings,
      );
      _expectNoLayoutFindings(findings: findings, viewport: viewport);
    });
  }

  testWidgets('登录页覆盖最窄屏与 1.5 倍字号', (tester) async {
    final findings = <String>[];
    await _setViewport(
      tester: tester,
      viewport: _largeTextAuditViewports.first,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    _collectLayoutFindings(
      tester: tester,
      scenario: '登录页 ${_largeTextAuditViewports.first.name}',
      findings: findings,
    );
    _expectNoLayoutFindings(
      findings: findings,
      viewport: _largeTextAuditViewports.first,
    );
  });

  testWidgets('应用页长简介在窄屏大字号下不溢出', (tester) async {
    final findings = <String>[];
    const viewport = _AuditViewport(
      name: '320x568@1.3 应用页长简介',
      size: Size(320, 568),
      textScale: 1.3,
    );
    await _pumpDashboard(
      tester: tester,
      viewport: viewport,
      findings: findings,
    );
    await _tapMobileTab(tester: tester, label: '应用');
    _collectLayoutFindings(
      tester: tester,
      scenario: viewport.name,
      findings: findings,
    );
    _expectNoLayoutFindings(findings: findings, viewport: viewport);
  });
}

Future<void> _pumpDashboard({
  required WidgetTester tester,
  required _AuditViewport viewport,
  required List<String> findings,
}) async {
  await _setViewport(tester: tester, viewport: viewport);
  LiveActivityController.instance.resetForTest();
  debugHideEcardForTests = false;
  debugDisableEcardDirectForTests = true;
  final navTabs = viewport.size.width < 720
      ? NavTabConfig.defaultNavBar
      : [
          ...NavTabConfig.available.map((tab) => tab.tabId),
          NavTabConfig.moreTab.tabId,
        ];
  SharedPreferences.setMockInitialValues(<String, Object>{
    'nav_bar_config': navTabs,
  });
  addTearDown(() {
    debugHideEcardForTests = false;
    debugDisableEcardDirectForTests = false;
    LiveActivityController.instance.resetForTest();
  });

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: DashboardShell(
          api: _buildAuditApi(),
          studentName: _longStudentName,
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          onLogout: () {},
          isAdmin: true,
          isOwner: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  _collectLayoutFindings(
    tester: tester,
    scenario: 'Dashboard ${viewport.name}',
    findings: findings,
  );
}

Future<void> _setViewport({
  required WidgetTester tester,
  required _AuditViewport viewport,
}) async {
  tester.view.physicalSize = viewport.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _auditAllNavigationTabs({
  required WidgetTester tester,
  required _AuditViewport viewport,
  required List<String> findings,
}) async {
  if (viewport.size.width < 720) {
    await _auditCompactTabs(
      tester: tester,
      viewport: viewport,
      findings: findings,
    );
    return;
  }
  await _auditSidebarTabs(
    tester: tester,
    viewport: viewport,
    findings: findings,
  );
}

Future<void> _auditSidebarTabs({
  required WidgetTester tester,
  required _AuditViewport viewport,
  required List<String> findings,
}) async {
  const tabs = [
    '首页',
    '个人信息',
    '通知',
    '业务',
    '应用',
    '课表',
    '自动请假',
    '考勤',
    '考试',
    '成绩',
    '学分',
    '生活缴费',
    '作业上传',
    '更多',
  ];
  for (final tab in tabs) {
    await _tapSidebarTab(tester: tester, label: tab);
    _collectLayoutFindings(
      tester: tester,
      scenario: '$tab ${viewport.name}',
      findings: findings,
    );
  }
}

Future<void> _auditCompactTabs({
  required WidgetTester tester,
  required _AuditViewport viewport,
  required List<String> findings,
}) async {
  const bottomLabels = ['首页', '信息', '应用', '课表'];
  for (final label in bottomLabels) {
    await _tapMobileTab(tester: tester, label: label);
    _collectLayoutFindings(
      tester: tester,
      scenario: '$label ${viewport.name}',
      findings: findings,
    );
  }

  const moreTabs = [
    '通知',
    '业务',
    '请假',
    '考勤',
    '考试',
    '成绩',
    '学分',
    '缴费',
    '上传',
  ];
  for (final label in moreTabs) {
    await _tapMobileTab(tester: tester, label: '更多');
    final finder = find.descendant(
      of: find.byType(MorePage),
      matching: find.text(label),
    );
    await tester.tap(finder.last);
    await tester.pumpAndSettle();
    _collectLayoutFindings(
      tester: tester,
      scenario: '$label ${viewport.name}',
      findings: findings,
    );
  }
}

Future<void> _auditHighRiskTabs({
  required WidgetTester tester,
  required _AuditViewport viewport,
  required List<String> findings,
}) async {
  final usesMobileNavigation =
      find.byKey(const ValueKey('app-sidebar')).evaluate().isEmpty;
  if (usesMobileNavigation) {
    await _tapMobileTab(tester: tester, label: '首页');
    _collectLayoutFindings(
      tester: tester,
      scenario: '首页 ${viewport.name}',
      findings: findings,
    );
    await _tapMobileTab(tester: tester, label: '课表');
    _collectLayoutFindings(
      tester: tester,
      scenario: '课表 ${viewport.name}',
      findings: findings,
    );
    await _tapMobileTab(tester: tester, label: '更多');
    for (final label in const ['考试', '成绩', '缴费']) {
      await tester.tap(
        find
            .descendant(
              of: find.byType(MorePage),
              matching: find.text(label),
            )
            .last,
      );
      await tester.pumpAndSettle();
      _collectLayoutFindings(
        tester: tester,
        scenario: '$label ${viewport.name}',
        findings: findings,
      );
      await _tapMobileTab(tester: tester, label: '更多');
    }
    return;
  }

  for (final tab in const ['首页', '课表', '考试', '成绩', '生活缴费']) {
    await _tapSidebarTab(tester: tester, label: tab);
    _collectLayoutFindings(
      tester: tester,
      scenario: '$tab ${viewport.name}',
      findings: findings,
    );
  }
}

Future<void> _tapMobileTab({
  required WidgetTester tester,
  required String label,
}) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('mobile-bottom-nav')),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapSidebarTab({
  required WidgetTester tester,
  required String label,
}) async {
  final finder = find.descendant(
    of: find.byKey(const ValueKey('app-sidebar')),
    matching: find.text(label),
  );
  final sidebarScrollView = find.descendant(
    of: find.byKey(const ValueKey('app-sidebar')),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: sidebarScrollView,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _collectLayoutFindings({
  required WidgetTester tester,
  required String scenario,
  required List<String> findings,
}) {
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    final exceptionText = exception is FlutterError
        ? exception.toStringDeep()
        : exception.toString();
    findings.add('$scenario: $exceptionText');
  }
}

void _expectNoLayoutFindings({
  required List<String> findings,
  required _AuditViewport viewport,
}) {
  expect(
    findings,
    isEmpty,
    reason: '${viewport.name} 存在布局异常；请保留以下复现条件：\n${findings.join('\n')}',
  );
}

const _longStudentName = '测试学生姓名极长用于验证系统字号放大后的顶部问候与个人资料布局';
const _longCourseName = '面向超长名称与跨平台辅助功能约束的移动应用系统设计与工程实践课程';
const _longLocation = '广州软件学院教学楼 A 区实验实训中心第十二层多媒体综合实验室 A-1208';

ApiClient _buildAuditApi() {
  final api = ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      final body = _responseFor(path: request.url.path);
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }),
  );
  api.useSession('overflow-audit-session');
  api.setStudentId('2024000000');
  return api;
}

Object _responseFor({required String path}) {
  final schedule = [
    {
      'name': _longCourseName,
      'teacher': '张老师（软件工程教研室课程负责人及实践教学指导教师）',
      'classroom': _longLocation,
      'weekday': DateTime.now().weekday,
      'startSection': 1,
      'endSection': 2,
      'weeks': '1-2,4-18',
    },
    {
      'name': '高等数学与工程应用基础',
      'teacher': '李老师',
      'classroom': '教学楼 B-301',
      'weekday': DateTime.now().weekday,
      'startSection': 5,
      'endSection': 6,
      'weeks': '1-18',
    },
  ];
  final info = {
    'studentId': '2024000000',
    'name': _longStudentName,
    'college': '软件工程学院与数字创意产业学院联合培养中心',
    'major': '软件工程（移动互联网与人工智能应用方向）',
    'className': '软件工程 2024 级创新实验班（产教融合专项）',
    'grade': '2024',
    'gender': '女',
    'idNumber': '440101200001011234',
    'birthDate': '2000-01-01',
    'ethnicity': '汉族',
    'politicalStatus': '共青团员',
    'phone': '13800138000',
    'email': 'layout.audit.student@example.test',
    'address': '广东省广州市从化区经济开发区高技术产业园软件学院学生宿舍 A 区 12 栋 1208',
  };
  final notices = [
    {
      'category': '教务通知',
      'title': '关于 $_longCourseName 期末考核、实验报告提交与课程设计答辩安排的通知',
      'summary': '请所有同学在规定时间内完成材料准备，并留意教室、批次和个人考试座位的变更信息。',
      'date': '2026-06-03',
    },
  ];
  final attendance = {
    'status': 'ok',
    'items': [
      {
        'courseName': _longCourseName,
        'courseCode': 'MOBILE-ENGINEERING-2026',
        'normal': 12,
        'late': 1,
        'leaveEarly': 0,
        'absent': 0,
        'leave': 1,
        'total': 14,
        'records': [
          {
            'date': '2026-06-03',
            'status': 'leave',
            'statusLabel': '请假',
            'count': 1,
            'time': '第 1-2 节 09:00-10:20',
            'remark': '已提交完整材料，等待辅导员和任课教师审批。',
          }
        ],
      }
    ],
  };
  final exams = [
    {
      'courseName': _longCourseName,
      'time': '2026-06-20 09:00',
      'location': _longLocation,
      'seat': '第十二考场第 108 号座位',
      'type': '期末闭卷考试与课程设计综合答辩',
    },
  ];
  final grades = [
    {
      'courseName': _longCourseName,
      'score': '92',
      'credit': '3.5',
      'gradePoint': '4.0',
    },
  ];
  final credits = [
    {
      'studentId': '2024000000',
      'name': _longStudentName,
      'major': '软件工程（移动互联网与人工智能应用方向）',
      'totalCredit': '160',
      'selectedCredit': '24',
      'requiredExpected': 100,
      'electiveExpected': 40,
      'otherExpected': 20,
      'requiredEarned': 50,
      'electiveEarned': 15,
      'otherEarned': 5,
    },
  ];
  final ecard = {
    'status': 'ok',
    'roomId': 'CGCOMMON1111|1|A2|932',
    'roomDisplay': '校本部学生宿舍 A 区 12 栋 A2-932（四人间）',
    'powerBalance': 9,
    'powerUnit': '度',
    'powerText': '9 度（低于提醒阈值）',
    'coldWaterBalance': 2,
    'coldWaterUnit': '吨',
    'coldWaterText': '2 吨（低于提醒阈值）',
    'hotWaterBalance': 12.5,
    'hotWaterUnit': '元',
    'hotWaterText': '12.5 元',
    'reminderEnabled': true,
    'lowPowerThreshold': 30,
  };

  switch (path) {
    case '/dashboard':
      return {
        'status': 'ok',
        'generatedAt': '2026-06-29T00:00:00Z',
        'modules': {
          'me': {'status': 'ok', 'data': info},
          'schedule': {'status': 'ok', 'data': schedule},
          'attendance': {'status': 'ok', 'data': attendance},
          'exams': {'status': 'ok', 'data': exams},
          'grades': {'status': 'ok', 'data': grades},
          'credits': {'status': 'ok', 'data': credits},
          'notices': {'status': 'ok', 'data': notices},
          'ecard': {'status': 'ok', 'data': ecard},
          'apps': {
            'status': 'ok',
            'data': [_applicationItem()],
          },
          'progress': {'status': 'ok', 'data': _progressOverview()},
          'weather': {'status': 'empty', 'data': null},
        },
      };
    case '/me':
      return info;
    case '/schedule':
      return schedule;
    case '/attendance':
      return attendance;
    case '/exams':
      return exams;
    case '/grades':
      return grades;
    case '/credits':
      return credits;
    case '/notices':
      return notices;
    case '/ecard/summary':
    case '/ecard/binding':
    case '/ecard/refresh':
    case '/ecard/reminder':
    case '/ecard/summary-cache':
      return ecard;
    case '/ecard/rooms':
      return [
        {
          'id': 'CGCOMMON1111|1|A2|932',
          'schoolArea': '校本部',
          'building': '学生宿舍 A 区 12 栋',
          'room': 'A2-932',
          'displayName': '校本部学生宿舍 A 区 12 栋 A2-932',
        },
      ];
    case '/ecard/consumption':
      return {
        'status': 'ok',
        'cachedAt': '2026-06-03T08:00:00+08:00',
        'items': [
          {
            'title': '2026 年 6 月 3 日超长用电记录说明',
            'amount': '2.5 度',
            'time': '2026-06-03 23:59',
            'date': '2026-06-03',
            'usage': 2.5,
            'unit': '度',
          }
        ],
      };
    case '/ecard/consumption/overview':
      return {
        'status': 'ok',
        'months': [
          {
            'month': '2026-06',
            'recordedDays': 3,
            'totalUsage': 8.5,
            'averageDailyUsage': 2.83,
            'peakDate': '2026-06-03',
            'peakUsage': 4.0,
            'unit': '度',
            'cachedAt': '2026-06-03T08:00:00+08:00',
          }
        ],
      };
    case '/ehall/affairs':
    case '/ehall/applications':
      return [_applicationItem()];
    case '/ehall/progress':
      return _progressOverview();
    case '/ehall/leave/preview':
      return {
        'status': 'ok',
        'hasMissingFields': false,
        'items': [
          {
            'courseName': _longCourseName,
            'courseCode': 'MOBILE-ENGINEERING-2026',
            'teachingClassCode': 'JXB001',
            'courseNature': '必修',
            'credit': '3.5',
            'classTime': '2026-03-09 第 1-2 节 09:00-10:20',
            'classTimes': ['2026-03-09 第 1-2 节 09:00-10:20'],
            'absenceCount': 1,
            'teacher': '张老师（软件工程教研室）',
            'missingFields': [],
          }
        ],
      };
    default:
      return <String, Object>{};
  }
}

Map<String, Object> _applicationItem() => {
      'id': 'affair-layout-audit',
      'title': '学生课程请假、成绩复核与跨学院学分认定综合服务申请',
      'department': '教务处学生事务与教学运行服务中心',
      'type': '学生事务综合办理',
      'tags': ['常用服务', '需要材料', '审批流程较长'],
      'summary': '提交前请准备完整证明材料，并确认课程、学期与联系方式均正确。',
      'url': 'https://ehall.example.test/affair-layout-audit',
    };

Map<String, Object> _progressOverview() => {
      'categories': [
        {'label': '申请', 'count': 1},
      ],
      'items': [
        {
          'id': 'progress-layout-audit',
          'title': '学生课程请假、成绩复核与跨学院学分认定综合服务申请',
          'category': '申请',
          'status': 'processing',
          'statusLabel': '辅导员审核中',
          'date': '2026-06-03',
          'summary': '当前步骤：辅导员审核，后续还需任课教师与教务处确认。',
          'currentNode': '辅导员审核与任课教师联合确认',
          'handler': '张老师（软件工程学院学生工作办公室）',
          'progress': 60,
          'url': 'https://ehall.example.test/progress-layout-audit',
        }
      ],
    };
