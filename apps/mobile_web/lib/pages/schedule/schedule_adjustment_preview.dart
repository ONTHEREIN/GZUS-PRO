import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../schedule_utils.dart';

Widget scheduleAdjustmentOccurrences(
        BuildContext context, String title, List<ScheduleOccurrence> rows) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      if (rows.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('没有课程')),
      for (final o in rows)
        Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border(
                    left: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 4))),
            child: Text(
                '${dateText(o.date)} · 第${o.course.startSection}–${o.course.endSection}节\n${o.course.name}\n${o.course.classroom ?? ''} ${o.course.teacher ?? ''}'))
    ]);

Widget scheduleAdjustmentComparison(BuildContext context,
        List<ScheduleOccurrence> before, List<ScheduleOccurrence> after) =>
    LayoutBuilder(builder: (_, constraints) {
      final a = scheduleAdjustmentOccurrences(context, '调整前', before),
          b = scheduleAdjustmentOccurrences(context, '调整后', after);
      return constraints.maxWidth >= 650
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: a),
              const SizedBox(width: 20),
              Expanded(child: b)
            ])
          : Column(children: [a, const SizedBox(height: 16), b]);
    });

/// 整批结果按日期展示，未变化课程折叠，文字标明拆分与移动方向。
Widget scheduleAdjustmentBatchResult(
    BuildContext context, AdjustmentPreview preview) {
  bool unchanged(ScheduleOccurrence a) => preview.before.any((b) =>
      a.occurrenceKey == b.occurrenceKey &&
      a.date == b.date &&
      a.course.startSection == b.course.startSection &&
      a.course.endSection == b.course.endSection);
  String label(ScheduleOccurrence a) {
    final ancestors = preview.before.where((b) =>
        a.occurrenceKey == b.occurrenceKey ||
        a.occurrenceKey.startsWith('${b.occurrenceKey}:') ||
        a.occurrenceKey.startsWith('${b.occurrenceKey}->'));
    if (ancestors.isEmpty) throw StateError('预览课程缺少来源实例：${a.occurrenceKey}');
    final b = ancestors.first;
    if (a.date == b.date &&
        a.course.startSection! >= b.course.startSection! &&
        a.course.endSection! <= b.course.endSection!) {
      return '拆分后保留';
    }
    final returned = preview.pairs.any((row) =>
        row.pair.action == 'swap' &&
        b.date == row.pair.targetDate &&
        b.course.startSection! <= row.pair.targetEnd &&
        row.pair.targetStart <= b.course.endSection! &&
        a.date == row.pair.sourceDate);
    return returned ? '交换返回' : '移入';
  }

  final changed = preview.after.where((a) => !unchanged(a)).toList();
  final retained = preview.after.where(unchanged).toList();
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('整批调整后的课程', style: Theme.of(context).textTheme.titleLarge),
    for (final a in changed) ...[
      Text(label(a), style: Theme.of(context).textTheme.labelLarge),
      scheduleAdjustmentOccurrences(context, dateText(a.date), [a])
    ],
    for (final row in preview.pairs.where((p) => p.pair.action == 'replace'))
      for (final o in row.conflicts)
        Text(
            '覆盖移除：${o.course.name} · ${dateText(o.date)} · 第${o.course.startSection! > row.pair.targetStart ? o.course.startSection : row.pair.targetStart}–${o.course.endSection! < row.pair.targetEnd ? o.course.endSection : row.pair.targetEnd}节'),
    if (retained.isNotEmpty)
      ExpansionTile(
          title: Text('未变化课程（${retained.length}次）'),
          children: [scheduleAdjustmentOccurrences(context, '保持原安排', retained)])
  ]);
}
