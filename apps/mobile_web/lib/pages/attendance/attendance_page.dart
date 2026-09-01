import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../app_providers.dart';
import '../../schedule_utils.dart';
import '../../local_notification_service.dart'
    deferred as local_notification_service;
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';
import '../../widgets/progress.dart';

class AttendancePage extends ConsumerStatefulWidget {
  const AttendancePage(
      {super.key,
      required this.api,
      required this.year,
      required this.term,
      this.onSessionExpired});

  final ApiClient api;
  final int year;
  final int term;
  final VoidCallback? onSessionExpired;

  @override
  ConsumerState<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends ConsumerState<AttendancePage>
    with PageSilentRefresh<AttendancePage> {
  String _sortField = 'none';
  bool _sortDescending = true;
  String _filterType = 'all';
  DateTime? _selectedAttendanceDate;
  Set<String> _highlightedAttendanceKeys = {};
  String? _processedAttendanceSignature;
  bool _forceRefresh = false;
  int _detailRefreshVersion = 0;

  AttendanceRequest get _request => AttendanceRequest(
        client: widget.api,
        year: widget.year,
        term: widget.term,
        forceRefresh: _forceRefresh,
      );

  Future<void> _refreshAttendance() async {
    setState(() {
      _forceRefresh = true;
      _detailRefreshVersion += 1;
    });
    final request = _request;
    ref.invalidate(attendanceProvider(request));
    try {
      await ref.read(attendanceProvider(request).future);
    } catch (error) {
      if (mounted) showRefreshFailure(context, error);
    } finally {
      if (mounted) setState(() => _forceRefresh = false);
    }
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() => _detailRefreshVersion += 1);
    ref.invalidate(attendanceProvider(_request));
  }

  String get _sortLabel {
    const labels = {
      'normal': '正常',
      'late': '迟到',
      'leaveEarly': '早退',
      'absent': '旷课',
      'leave': '请假'
    };
    return '${labels[_sortField] ?? ''}${_sortDescending ? '↓' : '↑'}';
  }

  Widget _sourceHint(DataSourceInfo source) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          source.displayText,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onTertiaryContainer,
          ),
        ),
      );

  List<AttendanceItem> _applyFilterSort(List<AttendanceItem> items) {
    var filtered = items;
    if (_filterType != 'all') {
      filtered = items.where((item) {
        switch (_filterType) {
          case 'late':
            return item.late > 0;
          case 'leaveEarly':
            return item.leaveEarly > 0;
          case 'absent':
            return item.absent > 0;
          case 'leave':
            return item.leave > 0;
          default:
            return true;
        }
      }).toList();
    }
    if (_sortField != 'none') {
      filtered = [...filtered]..sort((a, b) {
          int va, vb;
          switch (_sortField) {
            case 'normal':
              va = a.normal;
              vb = b.normal;
            case 'late':
              va = a.late;
              vb = b.late;
            case 'leaveEarly':
              va = a.leaveEarly;
              vb = b.leaveEarly;
            case 'absent':
              va = a.absent;
              vb = b.absent;
            case 'leave':
              va = a.leave;
              vb = b.leave;
            default:
              return 0;
          }
          return _sortDescending ? vb.compareTo(va) : va.compareTo(vb);
        });
    } else {
      filtered = [...filtered]..sort((a, b) {
          final abnormalA = a.late + a.leaveEarly + a.absent;
          final abnormalB = b.late + b.leaveEarly + b.absent;
          if (abnormalA != abnormalB) return abnormalB.compareTo(abnormalA);
          return _attendanceStatusTotal(b).compareTo(_attendanceStatusTotal(a));
        });
    }
    if (_highlightedAttendanceKeys.isNotEmpty) {
      filtered = [...filtered]..sort((a, b) {
          final ah = _highlightedAttendanceKeys.contains(a.compareKey);
          final bh = _highlightedAttendanceKeys.contains(b.compareKey);
          if (ah == bh) return 0;
          return ah ? -1 : 1;
        });
    }
    return filtered;
  }

  Widget _buildToolbar(List<AttendanceItem> items) {
    final dayRecords = _selectedAttendanceDate == null
        ? const <_AttendanceDayRecord>[]
        : _recordsForDate(items, _selectedAttendanceDate!);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final item in const [
          ('all', '全部'),
          ('late', '迟到'),
          ('leaveEarly', '早退'),
          ('absent', '旷课'),
          ('leave', '请假'),
        ])
          ChoiceChip(
            label: Text(item.$2),
            selected: _filterType == item.$1,
            onSelected: (_) => setState(() => _filterType = item.$1),
          ),
        PopupMenuButton<String>(
          icon: IconLabel(
            icon: Icons.sort,
            label: _sortField == 'none' ? '异常优先' : _sortLabel,
          ),
          onSelected: (value) {
            if (value == 'none') {
              setState(() => _sortField = 'none');
            } else if (value == _sortField) {
              setState(() => _sortDescending = !_sortDescending);
            } else {
              setState(() {
                _sortField = value;
                _sortDescending = true;
              });
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'none', child: Text('异常优先')),
            PopupMenuItem(value: 'normal', child: Text('按正常次数')),
            PopupMenuItem(value: 'late', child: Text('按迟到次数')),
            PopupMenuItem(value: 'leaveEarly', child: Text('按早退次数')),
            PopupMenuItem(value: 'absent', child: Text('按旷课次数')),
            PopupMenuItem(value: 'leave', child: Text('按请假次数')),
          ],
        ),
        OutlinedButton.icon(
          onPressed: () => _pickAttendanceDate(items),
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text(_selectedAttendanceDate == null
              ? '按天查询'
              : dateText(_selectedAttendanceDate!)),
        ),
        if (_selectedAttendanceDate != null)
          IconButton(
            tooltip: '清除日期',
            onPressed: () => setState(() => _selectedAttendanceDate = null),
            icon: const Icon(Icons.close),
          ),
        if (_selectedAttendanceDate != null)
          Text(
            '当天 ${dayRecords.fold(0, (sum, item) => sum + item.record.count)} 次',
            style: const TextStyle(fontSize: 12),
          ),
        IconButton(
          tooltip: '刷新考勤',
          onPressed: () => unawaited(_refreshAttendance()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final attendanceFuture = ref.watch(attendanceProvider(_request).future);
    return AsyncPanel<DataResult<AttendanceResponse>>(
      future: attendanceFuture,
      initialData:
          widget.api.cachedAttendance(year: widget.year, term: widget.term) ==
                  null
              ? null
              : DataResult(
                  data: widget.api
                      .cachedAttendance(year: widget.year, term: widget.term)!,
                ),
      onSessionExpired: widget.onSessionExpired,
      builder: (result) => LayoutBuilder(
        builder: (context, constraints) {
          final data = result.data;
          _queueAttendanceDiffCheck(data.items);
          final compact = constraints.maxWidth < 640;
          if (data.items.isEmpty) {
            return PagePanel(
              title: '考勤',
              icon: Icons.schedule,
              expandChild: true,
              child: RefreshIndicator(
                onRefresh: _refreshAttendance,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (result.source.isStale) _sourceHint(result.source),
                    const SizedBox(
                      height: 260,
                      child: EmptyState(message: '暂无考勤记录'),
                    ),
                  ],
                ),
              ),
            );
          }
          final filteredItems = _applyFilterSort(data.items);
          final dayRecords = _selectedAttendanceDate == null
              ? const <_AttendanceDayRecord>[]
              : _recordsForDate(data.items, _selectedAttendanceDate!);
          return PagePanel(
            title: '考勤',
            icon: Icons.schedule,
            expandChild: true,
            child: RefreshIndicator(
              onRefresh: _refreshAttendance,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (result.source.isStale) _sourceHint(result.source),
                  AttendanceOverview(items: data.items),
                  const SizedBox(height: 12),
                  _buildToolbar(data.items),
                  const SizedBox(height: 10),
                  if (_selectedAttendanceDate != null) ...[
                    _AttendanceHistoryPanel(records: dayRecords),
                    const SizedBox(height: 10),
                  ],
                  _AttendanceCourseSection(
                    api: widget.api,
                    year: widget.year,
                    term: widget.term,
                    items: filteredItems,
                    highlightedKeys: _highlightedAttendanceKeys,
                    compact: compact,
                    detailRefreshVersion: _detailRefreshVersion,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _queueAttendanceDiffCheck(List<AttendanceItem> items) {
    final signature = _attendanceSnapshotSignature(items);
    if (_processedAttendanceSignature == signature) return;
    _processedAttendanceSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAttendanceDiff(items, signature);
    });
  }

  Future<void> _checkAttendanceDiff(
      List<AttendanceItem> items, String signature) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'attendance.snapshot.${widget.api.namespace}.${widget.year}.${widget.term}';
    final previousText = prefs.getString(key);
    await prefs.setString(key, signature);
    if (previousText == null || previousText.isEmpty) return;
    final previousItems = _decodeAttendanceSnapshot(previousText);
    final changes = _attendanceAbnormalIncrements(previousItems, items);
    if (changes.isEmpty) {
      if (mounted && _highlightedAttendanceKeys.isNotEmpty) {
        setState(() => _highlightedAttendanceKeys = {});
      }
      return;
    }
    final changedKeys = changes.map((item) => item.item.compareKey).toSet();
    if (mounted) {
      setState(() => _highlightedAttendanceKeys = changedKeys);
    }
    final first = changes.first;
    final more = changes.length > 1 ? ' 等 ${changes.length} 条' : '';
    try {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.show(
        id: 7301,
        title: '考勤异常更新',
        body:
            '${first.item.courseName} 新增${first.statusLabel} ${first.delta} 次$more',
        extras: {'type': 'attendance_alert'},
      );
    } catch (_) {}
  }

  Future<void> _pickAttendanceDate(List<AttendanceItem> items) async {
    final dates = _attendanceDates(items);
    final initial = _selectedAttendanceDate ??
        (dates.isNotEmpty ? dates.last : DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate:
          dates.isNotEmpty ? dates.first : DateTime(DateTime.now().year - 1),
      lastDate:
          dates.isNotEmpty ? dates.last : DateTime(DateTime.now().year + 1),
    );
    if (picked != null) setState(() => _selectedAttendanceDate = picked);
  }
}

int _attendanceStatusTotal(AttendanceItem item) =>
    item.normal + item.late + item.leaveEarly + item.absent + item.leave;

String _attendanceSnapshotSignature(List<AttendanceItem> items) {
  final sorted = [...items]
    ..sort((a, b) => a.compareKey.compareTo(b.compareKey));
  return jsonEncode(sorted.map((item) => item.toSnapshotJson()).toList());
}

List<AttendanceItem> _decodeAttendanceSnapshot(String value) {
  try {
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((item) => AttendanceItem.fromJson(item))
        .toList();
  } catch (_) {
    return const [];
  }
}

List<_AttendanceChange> _attendanceAbnormalIncrements(
  List<AttendanceItem> previous,
  List<AttendanceItem> current,
) {
  final previousByKey = {for (final item in previous) item.compareKey: item};
  final changes = <_AttendanceChange>[];
  for (final item in current) {
    final old = previousByKey[item.compareKey];
    if (old == null) continue;
    for (final status in const ['late', 'leaveEarly', 'absent', 'leave']) {
      final delta = item.countFor(status) - old.countFor(status);
      if (delta > 0) {
        changes.add(_AttendanceChange(
          item: item,
          status: status,
          statusLabel: _attendanceStatusLabel(status),
          delta: delta,
        ));
      }
    }
  }
  return changes;
}

List<_AttendanceDayRecord> _recordsForDate(
    List<AttendanceItem> items, DateTime date) {
  final target = dateText(date);
  final records = <_AttendanceDayRecord>[];
  for (final item in items) {
    for (final record in item.records) {
      if (record.normalizedDate == target) {
        records.add(_AttendanceDayRecord(item: item, record: record));
      }
    }
  }
  records.sort((a, b) {
    final status = a.record.status.compareTo(b.record.status);
    if (status != 0) return status;
    return a.item.courseName.compareTo(b.item.courseName);
  });
  return records;
}

List<DateTime> _attendanceDates(List<AttendanceItem> items) {
  final values = <DateTime>{};
  for (final item in items) {
    for (final record in item.records) {
      final date = DateTime.tryParse(record.normalizedDate);
      if (date != null) values.add(DateTime(date.year, date.month, date.day));
    }
  }
  final sorted = values.toList()..sort();
  return sorted;
}

String _attendanceStatusLabel(String status) {
  return const {
        'late': '迟到',
        'leaveEarly': '早退',
        'absent': '旷课',
        'leave': '请假',
        'normal': '正常',
      }[status] ??
      status;
}

Color _attendanceStatusColor(BuildContext context, String status) {
  final colorScheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'late':
    case 'absent':
      return colorScheme.error;
    case 'leaveEarly':
      return colorScheme.tertiary;
    case 'leave':
      return colorScheme.secondary;
    default:
      return colorScheme.primary;
  }
}

class _AttendanceChange {
  const _AttendanceChange({
    required this.item,
    required this.status,
    required this.statusLabel,
    required this.delta,
  });

  final AttendanceItem item;
  final String status;
  final String statusLabel;
  final int delta;
}

class _AttendanceDayRecord {
  const _AttendanceDayRecord({required this.item, required this.record});

  final AttendanceItem item;
  final AttendanceRecord record;
}

class _AttendanceHistoryPanel extends StatelessWidget {
  const _AttendanceHistoryPanel({required this.records});

  final List<_AttendanceDayRecord> records;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const EmptyState(message: '当天暂无考勤明细'),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text('当天明细', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          for (final entry in records)
            ListTile(
              dense: true,
              leading: Icon(
                entry.record.status == 'normal'
                    ? Icons.check_circle
                    : Icons.warning,
                color: _attendanceStatusColor(context, entry.record.status),
              ),
              title: Text(entry.item.courseName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([
                entry.record.time,
                entry.record.remark,
              ]
                  .where((value) => value != null && value.isNotEmpty)
                  .join(' · ')),
              trailing: Text(
                '${entry.record.statusLabel ?? _attendanceStatusLabel(entry.record.status)} x${entry.record.count}',
                style: TextStyle(
                  color: _attendanceStatusColor(context, entry.record.status),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttendanceCourseSection extends StatelessWidget {
  const _AttendanceCourseSection({
    required this.api,
    required this.year,
    required this.term,
    required this.items,
    required this.highlightedKeys,
    required this.compact,
    required this.detailRefreshVersion,
  });

  final ApiClient api;
  final int year;
  final int term;
  final List<AttendanceItem> items;
  final Set<String> highlightedKeys;
  final bool compact;
  final int detailRefreshVersion;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const EmptyState(message: '没有匹配的课程');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '课程明细',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ),
            Text(
              '${items.length} 门',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (compact)
          Column(
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AttendanceCard(
                    key: ValueKey('attendance-card-${item.courseId}'),
                    api: api,
                    year: year,
                    term: term,
                    item: item,
                    total: _attendanceStatusTotal(item),
                    highlighted: highlightedKeys.contains(item.compareKey),
                    detailRefreshVersion: detailRefreshVersion,
                  ),
                ),
            ],
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final item in items)
                SizedBox(
                  width: 280,
                  child: _AttendanceCard(
                    key: ValueKey('attendance-card-${item.courseId}'),
                    api: api,
                    year: year,
                    term: term,
                    item: item,
                    total: _attendanceStatusTotal(item),
                    highlighted: highlightedKeys.contains(item.compareKey),
                    detailRefreshVersion: detailRefreshVersion,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _AttendanceCard extends ConsumerStatefulWidget {
  const _AttendanceCard({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.item,
    required this.total,
    required this.detailRefreshVersion,
    this.highlighted = false,
  });

  final ApiClient api;
  final int year;
  final int term;
  final AttendanceItem item;
  final int total;
  final bool highlighted;
  final int detailRefreshVersion;

  @override
  ConsumerState<_AttendanceCard> createState() => _AttendanceCardState();
}

class _AttendanceCardState extends ConsumerState<_AttendanceCard> {
  bool _expanded = false;
  bool _forceDetailsRefresh = false;

  AttendanceDetailRequest get _detailRequest => AttendanceDetailRequest(
        client: widget.api,
        year: widget.year,
        term: widget.term,
        courseId: widget.item.courseId,
        forceRefresh: _forceDetailsRefresh,
      );

  @override
  void didUpdateWidget(covariant _AttendanceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detailRefreshVersion != oldWidget.detailRefreshVersion) {
      _forceDetailsRefresh = true;
    }
  }

  void _retryDetails() {
    setState(() => _forceDetailsRefresh = true);
    ref.invalidate(attendanceDetailProvider(_detailRequest));
  }

  void _toggleDetails() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final item = widget.item;
    final total = widget.total;
    final abnormal = item.late + item.leaveEarly + item.absent;
    final rate = total <= 0 ? 0.0 : item.normal / total;
    final focusColor = abnormal > 0
        ? colorScheme.error
        : item.leave > 0
            ? colorScheme.secondary
            : colorScheme.primary;
    return GestureDetector(
      key: ValueKey('attendance-detail-toggle-${item.courseId}'),
      behavior: HitTestBehavior.opaque,
      onTap: item.courseId.isEmpty ? null : _toggleDetails,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: widget.highlighted
              ? colorScheme.errorContainer.withValues(alpha: 0.45)
              : colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: widget.highlighted
                ? colorScheme.error
                : colorScheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  abnormal > 0 ? Icons.warning_amber : Icons.check_circle,
                  color: focusColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.highlighted
                        ? '★ ${item.courseName}'
                        : item.courseName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                StatusPill(
                  label: abnormal > 0 ? '异常 $abnormal' : '正常',
                  color: focusColor,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '${(rate * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: focusColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: StaticProgressBar(value: rate)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _attendancePill(
                    context, '正常', item.normal, colorScheme.primary),
                _attendancePill(context, '迟到', item.late, colorScheme.error),
                _attendancePill(
                    context, '早退', item.leaveEarly, colorScheme.tertiary),
                _attendancePill(context, '旷课', item.absent, colorScheme.error),
                _attendancePill(
                    context, '请假', item.leave, colorScheme.secondary),
                _attendancePill(
                    context, '合计', total, colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: item.courseId.isEmpty ? null : _toggleDetails,
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(_expanded ? '收起点名明细' : '查看点名明细'),
            ),
            if (_expanded) _buildDetails(context),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    if (widget.item.courseId.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('该课程缺少明细查询标识，暂无法加载点名记录。'),
      );
    }
    final future = ref.watch(attendanceDetailProvider(_detailRequest).future);
    return FutureBuilder<DataResult<AttendanceDetailResponse>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('点名明细加载失败，请重试。'),
                TextButton.icon(
                  onPressed: _retryDetails,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          );
        }
        return _AttendanceDetailPanel(items: snapshot.data!.data.items);
      },
    );
  }

  Widget _attendancePill(
    BuildContext context,
    String label,
    int value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: value > 0 ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: value > 0
              ? color
              : Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AttendanceDetailPanel extends StatefulWidget {
  const _AttendanceDetailPanel({required this.items});

  final List<AttendanceDetail> items;

  @override
  State<_AttendanceDetailPanel> createState() => _AttendanceDetailPanelState();
}

class _AttendanceDetailPanelState extends State<_AttendanceDetailPanel> {
  static const _statusFilters = [
    ('all', '全部'),
    ('normal', '正常'),
    ('late', '迟到'),
    ('leaveEarly', '早退'),
    ('absent', '旷课'),
    ('leave', '请假'),
  ];

  String _statusFilter = 'all';

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('暂无点名明细。'),
      );
    }
    final visibleItems = _statusFilter == 'all'
        ? items
        : items.where((item) => item.status == _statusFilter).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('显示 ${visibleItems.length} / ${items.length} 条点名记录',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final filter in _statusFilters)
                ChoiceChip(
                  key: ValueKey('attendance-detail-status-${filter.$1}'),
                  label: Text(
                    '${filter.$2} ${filter.$1 == 'all' ? items.length : items.where((item) => item.status == filter.$1).length}',
                  ),
                  selected: _statusFilter == filter.$1,
                  onSelected: (_) => setState(() => _statusFilter = filter.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (visibleItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('该状态暂无点名记录。'),
            ),
          for (final item in visibleItems)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item.classDate} ${item.classTime}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      StatusPill(
                        label: item.statusLabel,
                        color: _attendanceStatusColor(context, item.status),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      _AttendanceDetailField('学年', item.academicYear),
                      _AttendanceDetailField('学期', item.term),
                      _AttendanceDetailField('开课学院', item.offeringCollege),
                      _AttendanceDetailField('课程代码', item.courseCode),
                      _AttendanceDetailField('课程名称', item.courseName),
                      _AttendanceDetailField('教学班', item.teachingClass),
                      _AttendanceDetailField('任课老师', item.teacher),
                      _AttendanceDetailField('点名时间', item.rollCallTime),
                      _AttendanceDetailField('节次', item.sections),
                      _AttendanceDetailField('学号', item.studentId),
                      _AttendanceDetailField('姓名', item.studentName),
                      _AttendanceDetailField('性别', item.gender),
                      _AttendanceDetailField('学院', item.college),
                      _AttendanceDetailField('年级', item.grade),
                      _AttendanceDetailField('专业', item.major),
                      _AttendanceDetailField('班级', item.className),
                      _AttendanceDetailField('备注', item.remark),
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

class _AttendanceDetailField extends StatelessWidget {
  const _AttendanceDetailField(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text('$label：$value', style: const TextStyle(fontSize: 12)),
    );
  }
}

class _AttendanceKeyMetric extends StatelessWidget {
  const _AttendanceKeyMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 142,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class AttendanceOverview extends StatelessWidget {
  const AttendanceOverview({super.key, required this.items});

  final List<AttendanceItem> items;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final normal = items.fold(0, (sum, item) => sum + item.normal);
    final late = items.fold(0, (sum, item) => sum + item.late);
    final leaveEarly = items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = items.fold(0, (sum, item) => sum + item.absent);
    final leave = items.fold(0, (sum, item) => sum + item.leave);
    final abnormal = late + leaveEarly + absent;
    final statusTotal = normal + late + leaveEarly + absent + leave;
    final total = items.fold(0, (sum, item) => sum + item.total);
    final displayTotal = statusTotal > 0 ? statusTotal : total;
    final rate = displayTotal <= 0 ? 0.0 : normal / displayTotal;
    final focusColor = abnormal > 0 ? colorScheme.error : colorScheme.primary;
    final focusTitle = abnormal > 0 ? '需要关注' : '考勤稳定';
    final focusText = abnormal > 0
        ? '迟到 $late · 早退 $leaveEarly · 旷课 $absent'
        : '当前没有迟到、早退或旷课记录';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: focusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  abnormal > 0 ? Icons.warning_amber : Icons.verified,
                  color: focusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      focusTitle,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      focusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Text(
                '${(rate * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: focusColor,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          StaticProgressBar(value: rate),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              _AttendanceKeyMetric(
                label: '合计',
                value: '$displayTotal 次',
                icon: Icons.list,
                color: colorScheme.primary,
              ),
              _AttendanceKeyMetric(
                label: '正常',
                value: '$normal',
                icon: Icons.check_circle,
                color: colorScheme.primary,
              ),
              _AttendanceKeyMetric(
                label: '异常',
                value: '$abnormal',
                icon: Icons.warning_amber,
                color: abnormal > 0 ? colorScheme.error : colorScheme.tertiary,
              ),
              _AttendanceKeyMetric(
                label: '请假',
                value: '$leave',
                icon: Icons.badge,
                color: colorScheme.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
