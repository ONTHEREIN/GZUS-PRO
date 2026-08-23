import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../live_activity_service.dart';
import '../../models/grade_models.dart';
import '../../local_notification_service.dart'
    deferred as local_notification_service;
import '../../live_update_service.dart' deferred as live_update_service;
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/data_table.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';
import '../../widgets/scale_tap.dart';

class GradesPage extends StatefulWidget {
  const GradesPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired,
      this.onNavigateToExam});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;
  final ValueChanged<String>? onNavigateToExam;

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage>
    with PageSilentRefresh<GradesPage> {
  late Future<List<GradeGroup>> _gradesFuture;
  late String _periodsSignature;

  @override
  void initState() {
    super.initState();
    _periodsSignature = periodSignature(widget.periods);
    _gradesFuture = _loadGrades();
  }

  @override
  void didUpdateWidget(covariant GradesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = periodSignature(widget.periods);
    if (oldWidget.api != widget.api || nextSignature != _periodsSignature) {
      _periodsSignature = nextSignature;
      _gradesFuture = _loadGrades();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshGrades,
      child: AsyncPanel<List<GradeGroup>>(
        future: _gradesFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = constraints.maxWidth.gzusBreakpoint;
            final compact = breakpoint == GzusBreakpoint.compact;
            final pane = GzusSizing.splitPaneAdaptive(
              constraints.maxWidth,
              breakpoint,
              mediumRatio: 0.42,
              expandedRatio: 0.36,
              largeRatio: 0.32,
              minSide: 260,
              maxSide: 340,
            );
            if (!compact) {
              final retakeCount = items.where((g) => g.hasRetake).length;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: pane.side,
                    child: PagePanel(
                      title: '成绩统计',
                      icon: Icons.bar_chart,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('共 ${items.length} 门课程'),
                          const SizedBox(height: 8),
                          Text('补考/重修: $retakeCount 门'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: '成绩',
                      icon: Icons.school,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: GradeGroupList(
                            groups: items, onExamTap: widget.onNavigateToExam),
                      ),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '成绩',
              icon: Icons.school,
              expandChild: true,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: GradeGroupList(
                    groups: items, onExamTap: widget.onNavigateToExam),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _refreshGrades() async {
    setState(() => _gradesFuture = _loadGrades(forceRefresh: true));
    await _gradesFuture;
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() => _gradesFuture = _loadGrades());
  }

  Future<List<GradeGroup>> _loadGrades({bool forceRefresh = false}) async {
    final results = await Future.wait([
      for (final period in widget.periods)
        widget.api
            .grades(
              year: period.year,
              term: period.term,
              forceRefresh: forceRefresh,
            )
            .then(
              (result) => [
                for (final item in result.data) GradeAttempt(period, item),
              ],
            )
            .catchError((_) => <GradeAttempt>[]),
    ]);
    final attempts = results.expand((items) => items).toList();
    unawaited(_notifyGradeUpdates(attempts));
    final groups = <String, GradeGroup>{};
    for (final attempt in attempts) {
      final normalizedKey = courseKey(attempt.grade.courseName);
      final key = normalizedKey.isEmpty
          ? '${attempt.period.label}:${attempt.grade.score ?? ''}'
          : normalizedKey;
      final group = groups[key];
      if (group == null) {
        groups[key] = GradeGroup(attempt);
      } else {
        group.attempts.add(attempt);
      }
    }
    return groups.values.toList();
  }

  Future<void> _notifyGradeUpdates(List<GradeAttempt> attempts) async {
    if (attempts.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'grades.live_update.$_periodsSignature';
    final current = _gradeSnapshot(attempts);
    final previousRaw = prefs.getString(key);
    await prefs.setString(key, jsonEncode(current));
    if (previousRaw == null || previousRaw.isEmpty) return;
    final previous = _decodeStringMap(previousRaw);
    final changed = attempts.where((attempt) {
      final snapshotKey = _gradeSnapshotKey(attempt);
      final oldValue = previous[snapshotKey];
      return (oldValue != null && oldValue != current[snapshotKey]) ||
          oldValue == null;
    }).toList();
    if (changed.isEmpty) return;
    final latest = changed.first;
    const title = '成绩更新';
    final score = latest.grade.score?.trim();
    final body = score == null || score.isEmpty
        ? '${latest.grade.courseName} 已发布成绩'
        : '${latest.grade.courseName}：$score';
    final eventId =
        'grade_update:${_gradeSnapshotKey(latest)}:${current[_gradeSnapshotKey(latest)]}';
    final extras = {
      'id': eventId,
      'type': 'grade_update',
      'liveUpdate': true,
      'style': 'progress',
      'shortCriticalText': '成绩',
      'progressMax': 100,
      'progressCurrent': 100,
    };
    LiveActivityController.instance.show(LiveActivityEvent(
      id: eventId,
      type: 'grade_update',
      title: title,
      body: body,
      style: 'progress',
      shortText: '成绩',
      targetTab: 'grades',
      ongoing: false,
      progress: 1,
    ));
    final notificationId = eventId.hashCode.abs();
    await live_update_service.loadLibrary();
    final posted = await live_update_service.LiveUpdateService.postLiveUpdate(
      id: notificationId,
      title: title,
      body: body,
      style: 'progress',
      shortCriticalText: '成绩',
      extras: extras,
      ongoing: false,
      progressMax: 100,
      progressCurrent: 100,
    );
    if (!posted) {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.show(
        id: notificationId,
        title: title,
        body: body,
        extras: extras,
      );
    }
  }

  Map<String, String> _gradeSnapshot(List<GradeAttempt> attempts) {
    return {
      for (final attempt in attempts)
        _gradeSnapshotKey(attempt): [
          attempt.grade.score ?? '',
          attempt.grade.gradePoint ?? '',
        ].join('|'),
    };
  }

  String _gradeSnapshotKey(GradeAttempt attempt) {
    return [
      attempt.period.year,
      attempt.period.term,
      courseKey(attempt.grade.courseName),
    ].join('|');
  }

  Map<String, String> _decodeStringMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return const {};
    }
  }
}

class GradeGroupList extends StatelessWidget {
  const GradeGroupList({super.key, required this.groups, this.onExamTap});

  final List<GradeGroup> groups;
  final ValueChanged<String>? onExamTap;

  @override
  Widget build(BuildContext context) {
    final border =
        BorderSide(color: Theme.of(context).colorScheme.outlineVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final group in groups)
                GradeMobileCard(
                  group: group,
                  onExamTap: onExamTap != null
                      ? () => onExamTap!(group.displayName)
                      : null,
                ),
            ],
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            children: [
              SimpleTableRow(
                values: const ['课程', '成绩', '学分', '绩点'],
                strong: true,
                border: border,
              ),
              for (final group in groups)
                GradeGroupRow(
                  group: group,
                  border: border,
                  onExamTap: onExamTap != null
                      ? () => onExamTap!(group.displayName)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }
}

class GradeMobileCard extends StatelessWidget {
  const GradeMobileCard({super.key, required this.group, this.onExamTap});

  final GradeGroup group;
  final VoidCallback? onExamTap;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    return MobileRecordCard(
      icon: group.hasRetake ? Icons.warning : Icons.school,
      title: group.displayName,
      subtitle: latest.period.label,
      highlight: group.hasRetake,
      rows: [
        (Icons.check_circle, '成绩', latest.grade.score ?? '-'),
        (Icons.auto_stories, '学分', latest.grade.credit ?? '-'),
        (Icons.bar_chart, '绩点', latest.grade.gradePoint ?? '-'),
        if (group.hasRetake) (Icons.list, '记录', '${group.attempts.length} 次'),
      ],
      trailing: onExamTap != null
          ? ScaleTap(
              onTap: onExamTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.assignment,
                        size: 12,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer),
                    const SizedBox(width: 2),
                    Text('考试',
                        style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer)),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class GradeGroupRow extends StatelessWidget {
  const GradeGroupRow(
      {super.key, required this.group, required this.border, this.onExamTap});

  final GradeGroup group;
  final BorderSide border;
  final VoidCallback? onExamTap;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    final examTag = onExamTap != null
        ? InkWell(
            onTap: onExamTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.assignment,
                      size: 12,
                      color:
                          Theme.of(context).colorScheme.onSecondaryContainer),
                  const SizedBox(width: 2),
                  Text('考试',
                      style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer)),
                ],
              ),
            ),
          )
        : null;
    final values = [
      group.displayName,
      latest.grade.score ?? '-',
      latest.grade.credit ?? '-',
      latest.grade.gradePoint ?? '-',
    ];
    if (!group.hasRetake) {
      if (examTag == null) {
        return SimpleTableRow(values: values, border: border);
      }
      return Container(
        decoration: BoxDecoration(
          border: Border(bottom: border),
        ),
        child: Row(
          children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: i == 0
                      ? Row(
                          children: [
                            Flexible(
                                child: Text(values[i],
                                    overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 6),
                            examTag,
                          ],
                        )
                      : Text(values[i], overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: accentFill(context),
        border: Border(bottom: border),
      ),
      child: ExpansionTile(
        title: SimpleTableRowContent(
          values: values,
          color: Theme.of(context).colorScheme.primary,
          strong: true,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '更多考试',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SimpleTable(
                  headers: const ['学期', '课程', '成绩', '学分', '绩点'],
                  rows: [
                    for (final attempt in group.attempts)
                      [
                        attempt.period.label,
                        attempt.grade.courseName,
                        attempt.grade.score ?? '-',
                        attempt.grade.credit ?? '-',
                        attempt.grade.gradePoint ?? '-',
                      ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
