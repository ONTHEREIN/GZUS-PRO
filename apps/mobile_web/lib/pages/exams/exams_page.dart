import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../calendar_import.dart';
import '../../models/grade_models.dart';
import '../../ics_download.dart' deferred as ics_download;
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/data_table.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';

class ExamsPage extends StatefulWidget {
  const ExamsPage(
      {super.key,
      required this.api,
      required this.periods,
      required this.year,
      required this.term,
      this.onSessionExpired,
      this.highlightCourse});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final int year;
  final int term;
  final VoidCallback? onSessionExpired;
  final String? highlightCourse;

  @override
  State<ExamsPage> createState() => _ExamsPageState();
}

class _ExamsPageState extends State<ExamsPage>
    with PageSilentRefresh<ExamsPage> {
  var sortMode = 'term';
  bool sortAscending = false;
  bool _exporting = false;
  late Future<List<PeriodExam>> _examsFuture;
  late String _periodsSignature;
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToHighlight = false;
  int _loadGeneration = 0;
  bool _isLoadingHistory = false;
  final Set<AcademicPeriod> _failedPeriods = {};
  DataSourceInfo? _staleSource;

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
    if (oldWidget.api != widget.api ||
        nextSignature != _periodsSignature ||
        oldWidget.year != widget.year ||
        oldWidget.term != widget.term) {
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
              final breakpoint = constraints.maxWidth.gzusBreakpoint;
              final wide = breakpoint != GzusBreakpoint.compact;
              final pane = GzusSizing.splitPaneAdaptive(
                constraints.maxWidth,
                breakpoint,
                mediumRatio: 0.38,
                expandedRatio: 0.34,
                largeRatio: 0.30,
                minSide: 240,
                maxSide: 320,
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: pane.side,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_hasLoadStatus) _loadStatus(context),
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
                                        final messenger =
                                            ScaffoldMessenger.maybeOf(context);
                                        setState(() => _exporting = true);
                                        try {
                                          final year =
                                              widget.periods.first.year;
                                          final term =
                                              widget.periods.first.term;
                                          final ics = generateExamIcs(
                                              exams: items,
                                              year: year,
                                              term: term);
                                          if (kIsWeb) {
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(
                                                ics, '考试_${year}_$term.ics');
                                          } else {
                                            final events = examCalendarEvents(
                                                exams: items,
                                                year: year,
                                                term: term);
                                            final added =
                                                await CalendarImportService
                                                    .importEvents(events);
                                            if (mounted) {
                                              messenger?.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                      '已向系统日历导入 $added 场考试'),
                                                  duration: const Duration(
                                                      seconds: 2),
                                                ),
                                              );
                                            }
                                          }
                                        } on CalendarImportException catch (e) {
                                          if (mounted) {
                                            messenger?.showSnackBar(
                                              SnackBar(
                                                content:
                                                    Text('日历导入失败：${e.message}'),
                                              ),
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
                              for (final entry
                                  in _groupedSections(items).entries)
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
                    if (_hasLoadStatus) _loadStatus(context),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
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
                          TextButton(
                            onPressed: items.isEmpty || _exporting
                                ? null
                                : () async {
                                    final messenger =
                                        ScaffoldMessenger.maybeOf(context);
                                    setState(() => _exporting = true);
                                    try {
                                      final year = widget.periods.first.year;
                                      final term = widget.periods.first.term;
                                      final ics = generateExamIcs(
                                          exams: items, year: year, term: term);
                                      if (kIsWeb) {
                                        await ics_download.loadLibrary();
                                        await ics_download.downloadIcs(
                                            ics, '考试_${year}_$term.ics');
                                      } else {
                                        final events = examCalendarEvents(
                                            exams: items,
                                            year: year,
                                            term: term);
                                        final added =
                                            await CalendarImportService
                                                .importEvents(events);
                                        if (mounted) {
                                          messenger?.showSnackBar(
                                            SnackBar(
                                              content:
                                                  Text('已向系统日历导入 $added 场考试'),
                                              duration:
                                                  const Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      }
                                    } on CalendarImportException catch (e) {
                                      if (mounted) {
                                        messenger?.showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('日历导入失败：${e.message}'),
                                          ),
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
    setState(() {
      _examsFuture = _loadExams(forceRefresh: true);
    });
    await _examsFuture;
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() {
      _examsFuture = _loadExams();
    });
  }

  Future<List<PeriodExam>> _loadExams({bool forceRefresh = false}) async {
    final generation = ++_loadGeneration;
    _failedPeriods.clear();
    _staleSource = null;
    _isLoadingHistory = false;
    final periods = _prioritizedPeriods();
    if (periods.isEmpty) return const [];
    final current = await _loadPeriod(periods.first, forceRefresh);
    if (!mounted || generation != _loadGeneration) return current.items;
    _recordSource(current.source);
    final exams = _prepareExams(current.items);
    if (periods.length > 1) {
      _isLoadingHistory = true;
      unawaited(_loadHistory(
        periods: periods.skip(1).toList(growable: false),
        initialExams: exams,
        forceRefresh: forceRefresh,
        generation: generation,
      ));
    }
    return exams;
  }

  List<AcademicPeriod> _prioritizedPeriods() {
    final current = AcademicPeriod(widget.year, widget.term);
    final history = widget.periods
        .where((period) =>
            period.year != current.year || period.term != current.term)
        .toList(growable: false)
      ..sort((left, right) =>
          periodSortValue(right).compareTo(periodSortValue(left)));
    return [current, ...history];
  }

  Future<_PeriodExamResult> _loadPeriod(
    AcademicPeriod period,
    bool forceRefresh,
  ) async {
    final result = await widget.api.exams(
      year: period.year,
      term: period.term,
      forceRefresh: forceRefresh,
    );
    return _PeriodExamResult(
      items: [for (final item in result.data) PeriodExam(period, item)],
      source: result.source,
    );
  }

  Future<void> _loadHistory({
    required List<AcademicPeriod> periods,
    required List<PeriodExam> initialExams,
    required bool forceRefresh,
    required int generation,
  }) async {
    var exams = [...initialExams];
    for (final period in periods) {
      try {
        final loaded = await _loadPeriod(period, forceRefresh);
        if (!mounted || generation != _loadGeneration) return;
        _recordSource(loaded.source);
        exams = _prepareExams([...exams, ...loaded.items]);
      } catch (_) {
        if (!mounted || generation != _loadGeneration) return;
        _failedPeriods.add(period);
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _examsFuture = Future.value(exams);
      });
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() => _isLoadingHistory = false);
  }

  void _recordSource(DataSourceInfo source) {
    if (source.isStale) _staleSource = source;
  }

  Widget _loadStatus(BuildContext context) {
    final source = _staleSource;
    final parts = <String>[
      if (source != null) source.displayText,
      if (_isLoadingHistory) '正在加载历史学期',
      if (_failedPeriods.isNotEmpty) '${_failedPeriods.length} 个学期暂未加载',
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' · '),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          if (_failedPeriods.isNotEmpty)
            TextButton(
              onPressed: _refreshExams,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }

  bool get _hasLoadStatus =>
      _isLoadingHistory || _failedPeriods.isNotEmpty || _staleSource != null;

  List<PeriodExam> _prepareExams(List<PeriodExam> exams) {
    final prepared = [...exams];
    final byCourse = <String, List<PeriodExam>>{};
    for (final exam in prepared) {
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
    return sortMode == 'term'
        ? _sortedByTerm(prepared)
        : _sortedByTime(prepared);
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

class _PeriodExamResult {
  const _PeriodExamResult({required this.items, required this.source});

  final List<PeriodExam> items;
  final DataSourceInfo source;
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
                        Expanded(
                          child: Text(
                            item.exam.time ?? '-',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on,
                            size: 16,
                            color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            item.exam.location ?? '-',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
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
