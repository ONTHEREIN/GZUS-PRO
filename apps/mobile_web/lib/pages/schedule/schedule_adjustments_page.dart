import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../models/schedule_override.dart';
import '../../schedule_adjustment_sync.dart';
import '../../schedule_utils.dart';
import 'schedule_date_selection.dart';
import 'schedule_adjustment_preview.dart';
import 'schedule_selection_week.dart';
import 'schedule_course_color.dart';
part 'schedule_adjustment_editor.dart';

/// 云端个人调课工作台，草稿独立于生效记录。
class ScheduleAdjustmentsPage extends StatefulWidget {
  const ScheduleAdjustmentsPage(
      {super.key,
      required this.api,
      required this.year,
      required this.term,
      required this.firstWeekStart,
      required this.courses,
      required this.overrides,
      required this.records,
      required this.onSave,
      required this.onRestore,
      required this.currentWeek,
      required this.presetCourse,
      required this.presetOccurrenceKey});
  final ApiClient api;
  final int year, term, currentWeek;
  final DateTime firstWeekStart;
  final List<ScheduleCourse> courses;
  final List<ScheduleOverride> overrides;
  final List<ScheduleAdjustmentRecord> records;
  final ScheduleCourse? presetCourse;
  final String? presetOccurrenceKey;
  final Future<List<ScheduleAdjustmentRecord>> Function(
      ScheduleAdjustmentRecord) onSave;
  final Future<List<ScheduleAdjustmentRecord>> Function(String) onRestore;
  @override
  State<ScheduleAdjustmentsPage> createState() =>
      _ScheduleAdjustmentsPageState();
}

class _ScheduleAdjustmentsPageState extends State<ScheduleAdjustmentsPage> {
  late final String _namespace = widget.api.namespace;
  late List<ScheduleAdjustmentRecord> _records = List.of(widget.records);
  List<ScheduleOccurrence> _courses = [];
  final Set<String> _keys = {};
  final List<DateTime> _sources = [], _targets = [];
  final Map<String, AdjustmentPair> _settings = {};
  AdjustmentPreview? _preview;
  AdjustmentRestorePreview? _restorePreview;
  ScheduleAdjustmentRecord? _restoring;
  String _screen = 'course', _operation = 'course', _clientId = '';
  String? _error;
  bool _busy = false, _loaded = false, _pending = false;
  late int _week = widget.currentWeek;
  int _courseStep = 0;
  int _groupIndex = 0;
  final Map<String, String> _rangeModes = {}, _targetModes = {};
  final Map<String, int> _targetWeekdays = {},
      _targetStarts = {},
      _fromWeeks = {};
  final Map<String, List<DateTime>> _groupTargets = {};
  Future<void> _draftWrite = Future.value();
  String get _draftKey =>
      'schedule.$_namespace.adjustmentDraft.${widget.year}.${widget.term}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _refresh(VoidCallback action) => setState(action);

  void _requireScope() {
    if (widget.api.namespace != _namespace) throw StateError('账号已切换，请重新打开调课');
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      _requireScope();
      final prefs = await SharedPreferences.getInstance();
      final snapshot = prefs.getString('$_draftKey.courses');
      if (_courses.isEmpty && snapshot != null) {
        _courses = occurrencesFromJson(jsonDecode(snapshot));
      }
      if (_courses.isEmpty && widget.courses.isNotEmpty) {
        _courses = expandEffectiveSchedule(
            courses: widget.courses,
            firstWeekStart: widget.firstWeekStart,
            adjustments: widget.records);
      }
      final draft = prefs.getString(_draftKey);
      if (draft != null && !_loaded && _sources.isEmpty) {
        final saved = jsonDecode(draft) as Map<String, dynamic>;
        final request = AdjustmentRequest.fromJson(saved);
        _operation = request.operation;
        _screen = _operation == 'course' ? 'course' : 'day';
        _targets.clear();
        _targets.addAll(
            (saved['targets'] as List).cast<String>().map(DateTime.parse));
        for (final p in request.pairs) {
          _sources.add(p.sourceDate);
          _keys.addAll(p.sourceKeys);
          _settings[p.itemId] = p;
          for (final key in p.sourceKeys) {
            final rows = _courses.where((o) => o.occurrenceKey == key);
            if (rows.isNotEmpty) {
              _targetModes[_identity(rows.first)] = 'individual';
            }
          }
        }
      }
      if (draft != null && !_loaded) {
        final saved = jsonDecode(draft) as Map<String, dynamic>;
        _restoreEditor(saved);
      }
      _pending = (await ScheduleAdjustmentSync.loadQueue(
              _namespace, widget.year, widget.term))
          .isNotEmpty;
      _courses = await widget.api
          .fetchDatedSchedule(widget.year, widget.term, widget.firstWeekStart);
      _requireScope();
      if (!await prefs.setString(
          '$_draftKey.courses',
          jsonEncode([
            for (final o in _courses)
              {
                ...o.course.toJson(),
                'teacher': o.course.teacher ?? '',
                'classroom': o.course.classroom ?? '',
                'itemKey': o.occurrenceKey,
                'date': dateText(o.date),
                'week': o.week
              }
          ]))) {
        throw StateError('生效课表离线快照保存失败');
      }
      _records = await widget.api
          .fetchScheduleAdjustments(year: widget.year, term: widget.term);
      _requireScope();
      if (draft != null) {
        final saved = jsonDecode(draft) as Map<String, dynamic>;
        final request = AdjustmentRequest.fromJson(saved);
        if (request.operation == 'partialDay') {
          _operation = 'course';
          _screen = 'course';
          _courseStep = 2;
          _settings.clear();
          for (final pair in request.pairs) {
            for (final key in pair.sourceKeys) {
              _settings[key] = AdjustmentPair(
                  sourceDate: pair.sourceDate,
                  targetDate: pair.targetDate,
                  sourceStart: pair.sourceStart,
                  sourceEnd: pair.sourceEnd,
                  targetStart: pair.targetStart,
                  sourceKeys: [key],
                  action: pair.action);
              final match = _courses.where((o) => o.occurrenceKey == key);
              if (match.isNotEmpty) {
                final group = _identity(match.first);
                _targetModes[group] = 'individual';
                _rangeModes[group] = 'selected';
              }
            }
          }
          _changed();
        }
      }
      _loaded = true;
      final preset = widget.presetCourse;
      if (preset != null && draft == null) {
        final matches = _courses
            .where((o) =>
                (widget.presetOccurrenceKey != null
                    ? o.occurrenceKey == widget.presetOccurrenceKey
                    : o.week == _week) &&
                o.course.name == preset.name &&
                o.course.teacher == preset.teacher &&
                o.course.classroom == preset.classroom &&
                o.course.startSection == preset.startSection &&
                o.course.weekday == preset.weekday)
            .toList();
        _screen = 'course';
        if (matches.length == 1 && widget.presetOccurrenceKey != null) {
          _keys.add(matches.single.occurrenceKey);
          _sources.add(matches.single.date);
          _week = matches.single.week;
          _courseStep = 0;
        }
      }
    } catch (error) {
      _error = '调课加载失败：$error。当前可编辑离线草稿，联网后重新预览才能生效。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _makePreview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireScope();
      if (_pending) throw StateError('请先返回课表同步或处理旧版待同步记录');
      final request = _request();
      final local = expandEffectiveSchedule(
          courses: widget.courses,
          firstWeekStart: widget.firstWeekStart,
          adjustments: const [],
          overrides: widget.overrides);
      final base = expandEffectiveSchedule(
          courses: widget.courses,
          firstWeekStart: widget.firstWeekStart,
          adjustments: const []);
      for (final day
          in request.pairs.expand((p) => [p.sourceDate, p.targetDate])) {
        String signature(List<ScheduleOccurrence> rows) => rows
            .where((o) => dateText(o.date) == dateText(day))
            .map((o) =>
                '${o.occurrenceKey}:${o.course.name}:${o.course.startSection}:${o.course.endSection}:${o.course.teacher}:${o.course.classroom}')
            .join('|');
        if (signature(local) != signature(base)) {
          throw StateError('${dateText(day)} 受本机课程编辑影响，请先在“本机课程编辑”中处理');
        }
      }
      final result = await widget.api.previewAdjustment(request);
      _requireScope();
      // 没有冲突自动解释为移动，冲突保留待选状态。
      for (final row in result.pairs) {
        if (_operation != 'day' &&
            row.conflicts.isEmpty &&
            row.pair.action == 'choose') {
          final p = row.pair;
          _settings[p.itemId] = AdjustmentPair(
              sourceDate: p.sourceDate,
              targetDate: p.targetDate,
              sourceStart: p.sourceStart,
              sourceEnd: p.sourceEnd,
              targetStart: p.targetStart,
              sourceKeys: p.sourceKeys,
              action: 'move');
        }
      }
      _preview = result;
      for (final row in result.pairs) {
        _settings[row.pair.itemId] = row.pair;
      }
      _clientId = 'flutter-${DateTime.now().microsecondsSinceEpoch}';
      _screen = 'preview';
    } catch (error) {
      _error = '预览失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireScope();
      final record = await widget.api
          .commitAdjustment(_request(), _clientId, _preview!.fingerprint);
      _requireScope();
      _records = [
        ..._records.where((r) => r.clientId != record.clientId),
        record
      ];
      _records = await widget.onSave(record);
      await _draftWrite;
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_draftKey)) throw StateError('调课已同步，但草稿清理失败');
      _sources.clear();
      _targets.clear();
      _keys.clear();
      _settings.clear();
      _rangeModes.clear();
      _targetModes.clear();
      _groupTargets.clear();
      _targetWeekdays.clear();
      _targetStarts.clear();
      _fromWeeks.clear();
      _courseStep = 0;
      _preview = null;
      _screen = 'history';
      _courses = await widget.api
          .fetchDatedSchedule(widget.year, widget.term, widget.firstWeekStart);
    } on ApiException catch (error) {
      _error = error.message;
      if (error.statusCode == 409) {
        _preview = null;
        _screen = _operation == 'course' ? 'course' : 'day';
      }
    } catch (error) {
      _error = '调课提交或后续刷新失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undoPreview(ScheduleAdjustmentRecord record) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireScope();
      _restorePreview = await widget.api
          .previewAdjustmentRestore(record, widget.firstWeekStart);
      _restoring = record;
      _screen = 'restore';
    } catch (error) {
      _error = '撤销预览失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireScope();
      final restored = await widget.api.restoreAdjustmentV2(
          _restoring!, widget.firstWeekStart, _restorePreview!.fingerprint);
      _requireScope();
      _records = [
        for (final r in _records) r.clientId == restored.clientId ? restored : r
      ];
      _records = await widget.onRestore(_restoring!.clientId);
      _screen = 'history';
      _restorePreview = null;
      _courses = await widget.api
          .fetchDatedSchedule(widget.year, widget.term, widget.firstWeekStart);
    } catch (error) {
      _error = '撤销失败：$error';
      _restorePreview = null;
      _screen = 'history';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String id, String label, int value, int first, int last,
          ValueChanged<int> changed) =>
      DropdownButtonFormField<int>(
          key: ValueKey('$id-$value'),
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [
            for (var n = first; n <= last; n++)
              DropdownMenuItem(value: n, child: Text('第$n节'))
          ],
          onChanged: _busy
              ? null
              : (v) {
                  if (v != null) changed(v);
                });

  List<Widget> _content() {
    if (_screen == 'history') {
      return [
        if (_records.isEmpty) const Text('本学期暂无调课记录'),
        for (final r in _records.reversed)
          Card(
              child: ExpansionTile(
                  key: ValueKey('adjustment-record-${r.clientId}'),
                  title: Text(
                      '${r.metadata?.request.operation == 'day' ? '整日交换' : r.metadata?.request.operation == 'dayCover' ? '整日覆盖' : r.metadata == null ? '旧版调课' : r.metadata!.request.operation == 'partialDay' ? '按天部分课程' : '课程调课'} · ${r.isActive ? '已同步 / 生效' : '已撤销'}'),
                  subtitle: Text(
                      '${r.metadata?.request.pairs.length ?? r.moves?.length ?? 1} ${r.metadata?.request.operation == 'day' || r.metadata?.request.operation == 'dayCover' ? '对日期' : '项调整'} · ${dateText(r.sourceDate)} → ${dateText(r.targetDate)}\n${r.metadata?.preview.pairs.expand((p) => p.before.map((o) => o.course.name)).toSet().join('、') ?? ''}\n${r.createdAt?.toLocal().toString() ?? '旧记录无时间信息'}'),
                  children: [
                if (r.metadata != null)
                  for (final p in r.metadata!.preview.pairs)
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(children: [
                          Text(p.labels.join(' · ')),
                          scheduleAdjustmentComparison(
                              context, p.before, p.after)
                        ]))
                else
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('旧记录仅保留原始操作，没有历史课程快照。')),
                if (r.isActive)
                  TextButton(
                      key: ValueKey('adjustment-undo-${r.clientId}'),
                      onPressed: _busy ? null : () => _undoPreview(r),
                      child: const Text('预览撤销'))
              ]))
      ];
    }
    if (_screen == 'restore' && _restorePreview != null) {
      return [
        if (_restorePreview!.blockers.isNotEmpty) ...[
          const Text('请先撤销以下关联的后续调课'),
          for (final id in _restorePreview!.blockers)
            ListTile(
                title: Text(_records
                            .firstWhere((r) => r.clientId == id)
                            .metadata
                            ?.request
                            .operation ==
                        'day'
                    ? '整日交换'
                    : _records
                                .firstWhere((r) => r.clientId == id)
                                .metadata
                                ?.request
                                .operation ==
                            'dayCover'
                        ? '整日覆盖'
                        : '课程调课'),
                subtitle: Text(id),
                onTap: () =>
                    _undoPreview(_records.firstWhere((r) => r.clientId == id)))
        ] else
          scheduleAdjustmentComparison(
              context, _restorePreview!.before, _restorePreview!.after)
      ];
    }
    if (_screen == 'preview' && _preview != null) {
      return [
        Text(
            '共 ${_preview!.pairs.length} 项调整，将影响 ${_preview!.affectedCount} 个课程实例'),
        if (_preview!.ready) scheduleAdjustmentBatchResult(context, _preview!),
        for (final message in _preview!.batchConflicts)
          Text(message,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        for (var i = 0; i < _preview!.pairs.length; i++) ...[
          const Divider(),
          Text(
              '配对 ${i + 1} · ${dateText(_preview!.pairs[i].pair.sourceDate)} ${_operation == 'dayCover' ? '→' : '↔'} ${dateText(_preview!.pairs[i].pair.targetDate)}'),
          if (_operation != 'day' &&
              _operation != 'dayCover' &&
              _preview!.pairs[i].conflicts.isNotEmpty)
            Wrap(spacing: 8, children: [
              for (final a in [('swap', '交换两侧区间'), ('replace', '覆盖目标冲突部分')])
                ChoiceChip(
                    key: ValueKey('adjustment-action-$i-${a.$1}'),
                    label: Text(a.$2),
                    selected: _preview!.pairs[i].pair.action == a.$1,
                    onSelected: _busy
                        ? null
                        : (_) {
                            final p = _preview!.pairs[i].pair;
                            _editPair(p, p.sourceStart, p.sourceEnd,
                                p.targetStart, a.$1);
                            _makePreview();
                          })
            ]),
          Text(_preview!.pairs[i].labels.join(' · ')),
          scheduleAdjustmentComparison(
              context, _preview!.pairs[i].before, _preview!.pairs[i].after),
        ]
      ];
    }
    return _editorContent();
  }

  @override
  Widget build(BuildContext context) {
    VoidCallback? action;
    String label = '';
    if (_screen == 'course' || _screen == 'day') {
      action = _validationError() == null ? _makePreview : null;
      label = '查看预览';
      if (_screen == 'course' && _courseStep < 2) {
        action = _selected.isEmpty
            ? null
            : () => setState(() {
                  _courseStep++;
                  _groupIndex = 0;
                });
        label = _courseStep == 0 ? '设置调整范围' : '设置目标时间';
      }
    }
    if (_screen == 'preview') {
      action = _preview?.ready == true ? _commit : null;
      label = _preview?.ready == true
          ? (_operation == 'day'
              ? '确认交换这 ${_preview!.pairs.length} 对日期'
              : _operation == 'dayCover'
                  ? '确认覆盖并移动这 ${_preview!.pairs.length} 天'
                  : '确认调整这 ${_preview!.pairs.length} 次课程')
          : '请先处理批内冲突';
    }
    if (_screen == 'restore') {
      action = _restorePreview?.blockers.isEmpty == true ? _undo : null;
      label = '确认撤销整批调课';
    }
    return Scaffold(
        appBar: AppBar(
            title: Text(_screen == 'home'
                ? '调课'
                : _screen == 'history'
                    ? '调课记录'
                    : _screen == 'restore'
                        ? '撤销预览'
                        : _operation == 'day'
                            ? '整日交换'
                            : _operation == 'dayCover'
                                ? '整日覆盖'
                                : '按课程调课'),
            actions: [
              IconButton(
                  key: const ValueKey('adjustment-entry-history'),
                  tooltip: '调课记录',
                  icon: const Icon(Icons.history),
                  onPressed:
                      _busy ? null : () => setState(() => _screen = 'history')),
              if (_screen == 'course' || _screen == 'day')
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton(
                        key: const ValueKey('adjustment-primary'),
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFF315A),
                            foregroundColor: Colors.white,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14)),
                        onPressed: _busy ||
                                (!_loaded &&
                                    !(_screen == 'course' && _courseStep < 2))
                            ? null
                            : action,
                        child: Text(_busy ? '处理中' : label)))
            ],
            leading: _screen == 'course' && _courseStep == 0
                ? null
                : IconButton(
                    key: const ValueKey('adjustment-back'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              if (_screen == 'course' && _courseStep > 0) {
                                _courseStep--;
                              } else {
                                _screen = _screen == 'preview'
                                    ? (_operation == 'course'
                                        ? 'course'
                                        : 'day')
                                    : _screen == 'restore'
                                        ? 'history'
                                        : 'course';
                              }
                            }))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ...[
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(
                onPressed: _busy ? null : _load, child: const Text('重新加载'))
          ],
          if (_keys.any((key) => !_courses.any((o) => o.occurrenceKey == key)))
            TextButton(
                key: const ValueKey('adjustment-clear-invalid'),
                onPressed: () {
                  _keys.removeWhere(
                      (key) => !_courses.any((o) => o.occurrenceKey == key));
                  _changed();
                },
                child: const Text('清除已失效课程，保留其他选择')),
          if (_pending) const Text('存在旧版待同步记录，请返回课表先完成同步。'),
          if (_screen == 'course' || _screen == 'day')
            SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'course', label: Text('按课程')),
                  ButtonSegment(value: 'day', label: Text('按天'))
                ],
                selected: {
                  _screen
                },
                onSelectionChanged:
                    _busy ? null : (v) => _switchEditor(v.single)),
          ..._content()
        ]),
        bottomNavigationBar: _screen == 'course' && _courseStep == 0
            ? SafeArea(
                child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextButton(
                        key: const ValueKey('adjustment-fixed-summary'),
                        onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => SafeArea(
                                child: SingleChildScrollView(
                                    child: _summary(_selected, '所选课程')))),
                        child: Text(
                            '已选 ${_groups.values.where((rows) => rows.isNotEmpty).length} 门教学安排，共 ${_selected.length} 次课程'))))
            : label.isEmpty || _screen == 'course' || _screen == 'day'
                ? null
                : SafeArea(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          FilledButton(
                              key: const ValueKey('adjustment-primary'),
                              onPressed: _busy ||
                                      (!_loaded &&
                                          !(_screen == 'course' &&
                                              _courseStep < 2))
                                  ? null
                                  : action,
                              child: Text(_busy ? '正在处理…' : label))
                        ]))));
  }
}
