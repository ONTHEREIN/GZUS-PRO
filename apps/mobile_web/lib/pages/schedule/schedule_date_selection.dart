import 'package:flutter/material.dart';

import '../../schedule_utils.dart';
import '../../api_client.dart';
import 'schedule_course_color.dart';

/// 月历多选，限制在学期范围和实际课程日期内。
class ScheduleDateSelection extends StatefulWidget {
  const ScheduleDateSelection(
      {super.key,
      required this.first,
      required this.selected,
      required this.allowed,
      required this.title,
      required this.courses});
  final DateTime first;
  final List<DateTime> selected;
  final Set<String>? allowed;
  final String title;
  final List<ScheduleOccurrence> courses;
  @override
  State<ScheduleDateSelection> createState() => _ScheduleDateSelectionState();
}

class _ScheduleDateSelectionState extends State<ScheduleDateSelection> {
  late DateTime _month = DateTime(
      (widget.selected.isEmpty ? widget.first : widget.selected.first).year,
      (widget.selected.isEmpty ? widget.first : widget.selected.first).month);
  late final Set<String> _selected = widget.selected.map(dateText).toSet();
  @override
  Widget build(BuildContext context) {
    final count = DateTime(_month.year, _month.month + 1, 0).day;
    final offset = _month.weekday - 1;
    return SafeArea(
        child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .78,
                child: Column(children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(children: [
                        Expanded(
                            child: Text(widget.title,
                                style: Theme.of(context).textTheme.titleLarge)),
                        IconButton(
                            tooltip: '关闭日期选择',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close))
                      ])),
                  Row(children: [
                    IconButton(
                        onPressed: () => setState(() =>
                            _month = DateTime(_month.year, _month.month - 1)),
                        icon: const Icon(Icons.chevron_left)),
                    Expanded(
                        child: Center(
                            child: Text('${_month.year}年${_month.month}月'))),
                    IconButton(
                        onPressed: () => setState(() =>
                            _month = DateTime(_month.year, _month.month + 1)),
                        icon: const Icon(Icons.chevron_right))
                  ]),
                  Row(children: [
                    for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                      Expanded(child: Center(child: Text(day)))
                  ]),
                  SizedBox(
                      height: 280,
                      child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 7),
                          itemCount: offset + count,
                          itemBuilder: (_, index) {
                            if (index < offset) return const SizedBox();
                            final date = DateTime(
                                _month.year, _month.month, index - offset + 1);
                            final text = dateText(date);
                            final enabled = !date.isBefore(widget.first) &&
                                date.isBefore(widget.first
                                    .add(const Duration(days: 210))) &&
                                (widget.allowed == null ||
                                    widget.allowed!.contains(text));
                            return TextButton(
                                key: ValueKey('adjustment-date-$text'),
                                onPressed: enabled
                                    ? () => setState(() {
                                          if (!_selected.remove(text)) {
                                            _selected.add(text);
                                          }
                                        })
                                    : null,
                                style: TextButton.styleFrom(
                                    backgroundColor: _selected.contains(text)
                                        ? const Color(0xFFFF315A)
                                        : Theme.of(context).colorScheme.surface,
                                    foregroundColor: _selected.contains(text)
                                        ? Colors.white
                                        : null,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14))),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(_selected.contains(text)
                                          ? '✓ ${date.day}'
                                          : '${date.day}'),
                                      Text(
                                          widget.courses.any((o) =>
                                                  dateText(o.date) == text)
                                              ? '${widget.courses.where((o) => dateText(o.date) == text).length}门'
                                              : '无课',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                  color:
                                                      _selected.contains(text)
                                                          ? Colors.white
                                                          : null))
                                    ]));
                          })),
                  Expanded(
                      child: ListView(children: [
                    for (final day in (_selected.toList()..sort()))
                      Card(
                          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18)),
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                        '$day · ${widget.courses.where((o) => dateText(o.date) == day).length}门课',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    for (final o in widget.courses
                                        .where((o) => dateText(o.date) == day))
                                      ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Container(
                                              width: 4,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                  color: scheduleCourseColor(
                                                      o.course.name),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          3))),
                                          title:
                                              Text(o.course.name, maxLines: 2),
                                          subtitle: Text(
                                              '${o.course.startSection}–${o.course.endSection}节 · ${o.course.classroom ?? ''} · ${o.course.teacher ?? ''}'))
                                  ])))
                  ])),
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                              key: const ValueKey('adjustment-date-confirm'),
                              style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFFF315A),
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14)),
                              onPressed: () => Navigator.pop(
                                  context,
                                  _selected.map(DateTime.parse).toList()
                                    ..sort()),
                              child: Text('确定（${_selected.length}天）'))))
                ]))));
  }
}
