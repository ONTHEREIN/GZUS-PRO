import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../api_client.dart';
import '../../models/grade_models.dart';
import '../../ics_download.dart' deferred as ics_download;
import '../../widgets/async_panel.dart';
import '../../widgets/data_table.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/page_panel.dart';

class ExamsPage extends StatefulWidget {
  const ExamsPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired,
      this.highlightCourse});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;
  final String? highlightCourse;

  @override
  State<ExamsPage> createState() => _ExamsPageState();
}

class _ExamsPageState extends State<ExamsPage> {
  var sortMode = 'term';
  bool sortAscending = false;
  bool _exporting = false;
  late Future<List<PeriodExam>> _examsFuture;
  late String _periodsSignature;
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToHighlight = false;

  @override
  void initState() {
    super.initState();
    _periodsSignature = periodSignature(widget.periods);
    _examsFuture = _loadExams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToHighlightIfNeeded();
    });
  }

  @override
  void didUpdateWidget(ExamsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = periodSignature(widget.periods);
    if (oldWidget.api != widget.api || nextSignature != _periodsSignature) {
      _periodsSignature = nextSignature;
      _examsFuture = _loadExams();
    }
    if (widget.highlightCourse != oldWidget.highlightCourse) {
      _hasScrolledToHighlight = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHighlightIfNeeded();
      });
    }
  }

  void _scrollToHighlightIfNeeded() {
    if (_hasScrolledToHighlight ||
        widget.highlightCourse == null ||
        !_scrollController.hasClients) {
      return;
    }
    final highlightKey = courseKey(widget.highlightCourse!);
    final items = _sortedByTerm(_allLoadedItems);
    int targetIndex = -1;
    for (int i = 0; i < items.length; i++) {
      if (courseKey(items[i].exam.courseName) == highlightKey) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) return; // 数据尚未加载，等待下次尝试
    _hasScrolledToHighlight = true;
    const estimatedItemHeight = 56.0;
    final scrollPosition = (targetIndex * estimatedItemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      scrollPosition,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  List<PeriodExam> _allLoadedItems = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshExams,
      child: AsyncPanel<List<PeriodExam>>(
        future: _examsFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (items) {
          _allLoadedItems = items;
          if (!_hasScrolledToHighlight && widget.highlightCourse != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToHighlightIfNeeded();
            });
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 160,
                              child: DropdownMenu<String>(
                                initialSelection: sortMode,
                                enableSearch: false,
                                requestFocusOnTap: false,
                                onSelected: (value) {
                                  if (value != null) {
                                    setState(() => sortMode = value);
                                  }
                                },
                                dropdownMenuEntries: const [
                                  DropdownMenuEntry(
                                      value: 'term', label: '按学期排列'),
                                  DropdownMenuEntry(
                                      value: 'time', label: '按时间排列'),
                                ],
                              ),
                            ),
                          ),
                          if (sortMode == 'term')
                            Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                icon: Icon(sortAscending
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward),
                                tooltip: sortAscending ? '正序' : '倒序',
                                onPressed: () => setState(
                                    () => sortAscending = !sortAscending),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: items.isEmpty || _exporting
                                  ? null
                                  : () async {
                                      setState(() => _exporting = true);
                                      try {
                                        final year = widget.periods.first.year;
                                        final term = widget.periods.first.term;
                                        final ics = generateExamIcs(
                                            exams: items,
                                            year: year,
                                            term: term);
                                        if (kIsWeb) {
                                          await ics_download.loadLibrary();
                                          ics_download.downloadIcs(
                                              ics, '考试_${year}_$term.ics');
                                        } else {
                                          await Share.shareXFiles(
                                            [
                                              XFile.fromData(utf8.encode(ics),
                                                  name: '考试_${year}_$term.ics',
                                                  mimeType: 'text/calendar')
                                            ],
                                            text: '考试_${year}_$term.ics',
                                          );
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _exporting = false);
                                        }
                                      }
                                    },
                              child: IconLabel(
                                icon: Icons.event_available,
                                label: _exporting ? '导出中...' : '导入至日历',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (sortMode == 'term')
                            for (final entry in _groupedSections(items).entries)
                              ListTile(
                                dense: true,
                                title: Text(entry.key,
                                    style: const TextStyle(fontSize: 14)),
                                trailing: Text('${entry.value.length}场',
                                    style: const TextStyle(fontSize: 13)),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: sortMode == 'term'
                            ? ExamTermSections(
                                items: items,
                                highlightCourse: widget.highlightCourse)
                            : ExamTable(
                                items: _sortedByTime(items),
                                highlightCourse: widget.highlightCourse),
                      ),
                    ),
                  ],
                );
              }
              return PagePanel(
                title: '考试',
                icon: Icons.assignment,
                expandChild: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 160,
                            child: DropdownMenu<String>(
                              initialSelection: sortMode,
                              enableSearch: false,
                              requestFocusOnTap: false,
                              onSelected: (value) {
                                if (value != null) {
                                  setState(() => sortMode = value);
                                }
                              },
                              dropdownMenuEntries: const [
                                DropdownMenuEntry(
                                    value: 'term', label: '按学期排列'),
                                DropdownMenuEntry(
                                    value: 'time', label: '按时间排列'),
                              ],
                            ),
                          ),
                          if (sortMode == 'term')
                            IconButton(
                              icon: Icon(sortAscending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward),
                              tooltip: sortAscending ? '正序' : '倒序',
                              onPressed: () => setState(
                                  () => sortAscending = !sortAscending),
                            ),
                          const Spacer(),
                          TextButton(
                            onPressed: items.isEmpty || _exporting
                                ? null
                                : () async {
                                    setState(() => _exporting = true);
                                    try {
                                      final year = widget.periods.first.year;
                                      final term = widget.periods.first.term;
                                      final ics = generateExamIcs(
                                          exams: items, year: year, term: term);
                                      if (kIsWeb) {
                                        await ics_download.loadLibrary();
                                        ics_download.downloadIcs(
                                            ics, '考试_${year}_$term.ics');
                                      } else {
                                        await Share.shareXFiles(
                                          [
                                            XFile.fromData(utf8.encode(ics),
                                                name: '考试_${year}_$term.ics',
                                                mimeType: 'text/calendar')
                                          ],
                                          text: '考试_${year}_$term.ics',
                                        );
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _exporting = false);
                                      }
                                    }
                                  },
                            child: IconLabel(
                              icon: Icons.event_available,
                              label: _exporting ? '导出中...' : '导入至日历',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: sortMode == 'term'
                            ? ExamTermSections(
                                items: items,
                                highlightCourse: widget.highlightCourse)
                            : ExamTable(
                                items: _sortedByTime(items),
                                highlightCourse: widget.highlightCourse),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _refreshExams() async {
    setState(() => _examsFuture = _loadExams(forceRefresh: true));
    await _examsFuture;
  }

  Future<List<PeriodExam>> _loadExams({bool forceRefresh = false}) async {
    final results = await Future.wait([
      for (final period in widget.periods)
        widget.api
            .exams(
              year: period.year,
              term: period.term,
              forceRefresh: forceRefresh,
            )
            .then(
              (result) => [
                for (final item in result.data) PeriodExam(period, item),
              ],
            )
            .catchError((_) => <PeriodExam>[]),
    ]);
    final exams = results.expand((items) => items).toList();
    final byCourse = <String, List<PeriodExam>>{};
    for (final exam in exams) {
      final key = courseKey(exam.exam.courseName);
      if (key.isEmpty) continue;
      byCourse.putIfAbsent(key, () => []).add(exam);
    }
    for (final courseExams in byCourse.values) {
      courseExams.sort(compareExamsByTimeAsc);
      for (var i = 0; i < courseExams.length; i++) {
        final exam = courseExams[i];
        exam.retakeIndex = i;
        if (courseExams.length == 1 &&
            (hasRetakeText(exam.exam.courseName) ||
                hasRetakeText(exam.exam.type))) {
          exam.retakeIndex = 1;
        }
      }
    }
    return sortMode == 'term' ? _sortedByTerm(exams) : _sortedByTime(exams);
  }

  List<PeriodExam> _sortedByTerm(List<PeriodExam> items) {
    return [...items]..sort((a, b) {
        final periodCompare =
            periodSortValue(a.period).compareTo(periodSortValue(b.period));
        if (periodCompare != 0) {
          return sortAscending ? periodCompare : -periodCompare;
        }
        return compareExamsByTime(a, b);
      });
  }

  List<PeriodExam> _sortedByTime(List<PeriodExam> items) =>
      [...items]..sort(compareExamsByTime);

  Map<String, List<PeriodExam>> _groupedSections(List<PeriodExam> items) {
    final sections = <String, List<PeriodExam>>{};
    for (final item in items) {
      sections.putIfAbsent(item.period.label, () => []).add(item);
    }
    return sections;
  }
}

class ExamTermSections extends StatelessWidget {
  const ExamTermSections(
      {super.key, required this.items, this.highlightCourse});

  final List<PeriodExam> items;
  final String? highlightCourse;

  @override
  Widget build(BuildContext context) {
    final sections = <String, List<PeriodExam>>{};
    for (final item in items) {
      sections.putIfAbsent(item.period.label, () => []).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in sections.entries) ...[
          Text(
            entry.key,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ExamTable(items: entry.value, highlightCourse: highlightCourse),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class ExamTable extends StatelessWidget {
  const ExamTable({super.key, required this.items, this.highlightCourse});

  final List<PeriodExam> items;
  final String? highlightCourse;

  @override
  Widget build(BuildContext context) {
    final highlightKey =
        highlightCourse != null ? courseKey(highlightCourse!) : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final item in items)
                MobileRecordCard(
                  icon: item.isRetake ? Icons.warning : Icons.assignment,
                  title: item.displayName,
                  subtitle: '${item.period.label} · ${item.examKind}',
                  highlight: item.isRetake,
                  highlighted: highlightKey != null &&
                      courseKey(item.exam.courseName) == highlightKey,
                  rows: [
                    (Icons.badge, '座位', item.exam.seat ?? '-'),
                  ],
                  extraRows: [
                    Row(
                      children: [
                        Icon(Icons.schedule,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(item.exam.time ?? '-',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on,
                            size: 16,
                            color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: 4),
                        Text(item.exam.location ?? '-',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.tertiary,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
            ],
          );
        }
        final highlightRows = <int>{};
        if (highlightKey != null) {
          for (var i = 0; i < items.length; i++) {
            if (courseKey(items[i].exam.courseName) == highlightKey) {
              highlightRows.add(i);
            }
          }
        }
        return SimpleTable(
          headers: const ['学期', '课程', '类型', '时间', '地点', '座位'],
          columnFlexs: const [2, 3, 2, 4, 3, 1],
          highlightedRows: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake || highlightRows.contains(i)) i,
          },
          rowHighlightColors: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i: retakeFill(items[i].retakeIndex),
            for (final i in highlightRows)
              if (!items[i].isRetake)
                i: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.3),
          },
          rowTextColors: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i: retakeText(items[i].retakeIndex),
          },
          rows: [
            for (final item in items)
              [
                item.period.label,
                item.displayName,
                item.examKind,
                item.exam.time ?? '-',
                item.exam.location ?? '-',
                item.exam.seat ?? '-',
              ],
          ],
        );
      },
    );
  }
}
