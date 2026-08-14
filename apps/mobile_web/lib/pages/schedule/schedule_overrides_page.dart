import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models/schedule_override.dart';
import '../../widgets/badges.dart';
import '../../widgets/empty_state.dart';

/// 课表「本地调课」管理页：列出本学期全部本地调课条目，可新增/编辑/删除。
/// 仅存本机（SharedPreferences），保存后通过 [onChanged] 通知课表页刷新。
class ScheduleOverridesPage extends StatefulWidget {
  const ScheduleOverridesPage({
    super.key,
    required this.year,
    required this.term,
    required this.items,
    required this.currentWeek,
    required this.onChanged,
  });

  final int year;
  final int term;
  /// 叠加后的课表（含本地条目），用于匹配下拉与条目展示。
  final List<ScheduleCourse> items;
  final int currentWeek;
  final VoidCallback onChanged;

  @override
  State<ScheduleOverridesPage> createState() => _ScheduleOverridesPageState();
}

class _ScheduleOverridesPageState extends State<ScheduleOverridesPage> {
  List<ScheduleOverride> _overrides = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ScheduleOverrideStore.load(widget.year, widget.term);
    if (!mounted) return;
    setState(() {
      _overrides = list;
      _loaded = true;
    });
  }

  Future<void> _saveOverride(ScheduleOverride override) async {
    final list = [..._overrides];
    final index = list.indexWhere((o) => o.id == override.id);
    if (index >= 0) {
      list[index] = override;
    } else {
      list.add(override);
    }
    await ScheduleOverrideStore.save(widget.year, widget.term, list);
    if (!mounted) return;
    setState(() => _overrides = list);
    widget.onChanged();
  }

  Future<void> _deleteOverride(ScheduleOverride override) async {
    final list =
        _overrides.where((o) => o.id != override.id).toList();
    await ScheduleOverrideStore.save(widget.year, widget.term, list);
    if (!mounted) return;
    setState(() => _overrides = list);
    widget.onChanged();
  }

  void _openEditor({ScheduleOverride? existing, ScheduleCourse? preset}) {
    showScheduleOverrideEditor(
      context,
      items: widget.items,
      existing: existing,
      presetCourse: preset,
      presetWeek: widget.currentWeek,
      onSave: _saveOverride,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地调课'),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新增调课'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _overrides.isEmpty
              ? const EmptyState(message: '暂无本地调课\n点右下角新增，或从课程详情进入')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 88),
                  itemCount: _overrides.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final override = _overrides[index];
                    return _OverrideTile(
                      entry: override,
                      items: widget.items,
                      onTap: () => _openEditor(existing: override),
                      onDelete: () => _deleteOverride(override),
                    );
                  },
                ),
    );
  }
}

class _OverrideTile extends StatelessWidget {
  const _OverrideTile({
    required this.entry,
    required this.items,
    required this.onTap,
    required this.onDelete,
  });

  final ScheduleOverride entry;
  final List<ScheduleCourse> items;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (String, Color) badge = switch (entry) {
      _ when entry.isAdd => ('新增', const Color(0xFF1E7A3C)),
      _ when entry.isHide => ('停课', const Color(0xFFB3261E)),
      _ => ('调整', const Color(0xFF8B4D00)),
    };
    final match = _matchCourseOf(entry, items);
    final title =
        entry.course?.name ?? match?.name ?? _matchKeyLabel(entry.matchKey);
    final subtitle = _overrideSubtitle(entry, match);
    final note = entry.note?.trim();

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusPill(label: badge.$1, color: badge.$2),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (note != null && note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: onDelete,
                tooltip: '删除',
                icon: Icon(Icons.delete_outline,
                    size: 20, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ScheduleCourse? _matchCourseOf(
    ScheduleOverride override, List<ScheduleCourse> items) {
  for (final item in items) {
    if (item.isLocal) continue;
    if (overrideMatches(override, item)) return item;
  }
  return null;
}

String _matchKeyLabel(String? matchKey) {
  if (matchKey == null) return '未命名';
  if (matchKey.startsWith('name:')) return matchKey.substring(5);
  if (matchKey.startsWith('kch:')) return '课程 ${matchKey.substring(4)}';
  return matchKey;
}

String _overrideSubtitle(
    ScheduleOverride override, ScheduleCourse? match) {
  final weeks = override.weeks?.trim();
  if (override.isHide) {
    return '停课周次：${(weeks == null || weeks.isEmpty) ? '全部周' : weeks}';
  }
  final course = override.course;
  if (course == null) return '';
  final newTime = _courseTimeText(course);
  final matchTime =
      match != null ? _courseTimeText(match) : null;
  if (override.isReplace && matchTime != null && matchTime != newTime) {
    return '原 $matchTime → $newTime';
  }
  return newTime;
}

String _courseTimeText(ScheduleCourse course) {
  final weekday = course.weekday;
  final start = course.startSection;
  final end = course.endSection ?? start;
  final weekdayText = weekday != null && weekday >= 1 && weekday <= 7
      ? '周${'一二三四五六日'[weekday - 1]}'
      : '星期?';
  final sectionText = start == null
      ? '节次待定'
      : '第$start-${(end != null && end >= start) ? end : start}节';
  return '$weekdayText $sectionText';
}

/// 打开本地调课编辑/新增表单（bottom sheet）。
///
/// [items] 为叠加后的课表（候选课程自动过滤本地条目）；[existing] 非空表示编辑；
/// [presetCourse] 为从课程详情进入时预填的匹配课程；[onSave] 保存完整列表变更。
Future<void> showScheduleOverrideEditor(
  BuildContext context, {
  required List<ScheduleCourse> items,
  ScheduleOverride? existing,
  ScheduleCourse? presetCourse,
  int? presetWeek,
  required Future<void> Function(ScheduleOverride override) onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _OverrideEditorSheet(
      items: items,
      existing: existing,
      presetCourse: presetCourse,
      presetWeek: presetWeek,
      onSave: onSave,
    ),
  );
}

enum _OverrideKind { add, replace, hide }

class _OverrideEditorSheet extends StatefulWidget {
  const _OverrideEditorSheet({
    required this.items,
    required this.existing,
    required this.presetCourse,
    required this.presetWeek,
    required this.onSave,
  });

  final List<ScheduleCourse> items;
  final ScheduleOverride? existing;
  final ScheduleCourse? presetCourse;
  final int? presetWeek;
  final Future<void> Function(ScheduleOverride override) onSave;

  @override
  State<_OverrideEditorSheet> createState() => _OverrideEditorSheetState();
}

class _OverrideEditorSheetState extends State<_OverrideEditorSheet> {
  /// 候选课程：学校课程（去本地条目 + 按名称/星期/节次去重）。
  late final List<ScheduleCourse> _candidates;
  late _OverrideKind _kind;
  ScheduleCourse? _matchCourse;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _classroomCtrl;
  late final TextEditingController _teacherCtrl;
  late final TextEditingController _weeksCtrl;
  late final TextEditingController _noteCtrl;
  int? _weekday;
  int? _startSection;
  int? _endSection;

  @override
  void initState() {
    super.initState();
    final seen = <String>{};
    _candidates = [
      for (final item in widget.items)
        if (!item.isLocal &&
            seen.add('${item.name}|${item.weekday}|${item.startSection}'))
          item,
    ];
    final existing = widget.existing;
    if (existing != null) {
      _kind = existing.isHide
          ? _OverrideKind.hide
          : (existing.isAdd ? _OverrideKind.add : _OverrideKind.replace);
      _matchCourse = _matchCourseOf(existing, _candidates);
      _nameCtrl = TextEditingController(text: existing.course?.name ?? '');
      _classroomCtrl =
          TextEditingController(text: existing.course?.classroom ?? '');
      _teacherCtrl =
          TextEditingController(text: existing.course?.teacher ?? '');
      _weeksCtrl = TextEditingController(
        text: existing.isHide
            ? (existing.weeks ?? '')
            : (existing.course?.weeks ?? ''),
      );
      _noteCtrl = TextEditingController(text: existing.note ?? '');
      _weekday = existing.course?.weekday;
      _startSection = existing.course?.startSection;
      _endSection = existing.course?.endSection;
    } else {
      _kind = widget.presetCourse != null
          ? _OverrideKind.replace
          : _OverrideKind.add;
      _matchCourse = widget.presetCourse;
      final preset = widget.presetCourse;
      _nameCtrl = TextEditingController(text: preset?.name ?? '');
      _classroomCtrl = TextEditingController(text: preset?.classroom ?? '');
      _teacherCtrl = TextEditingController(text: preset?.teacher ?? '');
      _weeksCtrl = TextEditingController(text: preset?.weeks ?? '');
      _noteCtrl = TextEditingController();
      _weekday = preset?.weekday;
      _startSection = preset?.startSection;
      _endSection = preset?.endSection;
    }
    if (_matchCourse == null &&
        widget.presetCourse != null &&
        widget.items.contains(widget.presetCourse)) {
      _matchCourse = widget.presetCourse;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _classroomCtrl.dispose();
    _teacherCtrl.dispose();
    _weeksCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    void warn(String message) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }

    final kind = _kind;
    String? matchKey;
    if (kind != _OverrideKind.add) {
      final match = _matchCourse;
      if (match == null) {
        warn('请选择要调整的课程');
        return;
      }
      matchKey = matchKeyForCourse(match);
    }
    if (kind == _OverrideKind.add && _nameCtrl.text.trim().isEmpty) {
      warn('请填写课程名称');
      return;
    }
    if (kind != _OverrideKind.hide) {
      if (_weekday == null) {
        warn('请选择星期');
        return;
      }
      if (_startSection == null) {
        warn('请选择开始节次');
        return;
      }
    }

    final weeksText = _weeksCtrl.text.trim();
    final weeks = weeksText.isEmpty ? null : weeksText;
    ScheduleCourse? course;
    if (kind != _OverrideKind.hide) {
      final start = _startSection!;
      final end = _endSection ?? start;
      course = ScheduleCourse(
        name: _nameCtrl.text.trim().isEmpty
            ? (_matchCourse?.name ?? '未命名')
            : _nameCtrl.text.trim(),
        teacher: _teacherCtrl.text.trim().isEmpty
            ? null
            : _teacherCtrl.text.trim(),
        classroom: _classroomCtrl.text.trim().isEmpty
            ? null
            : _classroomCtrl.text.trim(),
        weekday: _weekday,
        startSection: start,
        endSection: end >= start ? end : start,
        weeks: weeks,
      );
    }

    final override = ScheduleOverride(
      id: widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      matchKey: matchKey,
      matchWeekday: _matchCourse?.weekday,
      matchStartSection: _matchCourse?.startSection,
      weeks: kind == _OverrideKind.hide ? weeks : null,
      hidden: kind == _OverrideKind.hide,
      course: course,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );
    Navigator.pop(context);
    widget.onSave(override);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height * 0.9)
              .clamp(420.0, 860.0),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color:
                      colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 18 : 24,
                8,
                compact ? 18 : 24,
                0,
              ),
              child: Row(
                children: [
                  Text(
                    widget.existing == null ? '新增调课' : '编辑调课',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20, indent: 18, endIndent: 18),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 18 : 24,
                  0,
                  compact ? 18 : 24,
                  20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<_OverrideKind>(
                      segments: const [
                        ButtonSegment(
                          value: _OverrideKind.add,
                          icon: Icon(Icons.add),
                          label: Text('新增'),
                        ),
                        ButtonSegment(
                          value: _OverrideKind.replace,
                          icon: Icon(Icons.swap_horiz),
                          label: Text('调整'),
                        ),
                        ButtonSegment(
                          value: _OverrideKind.hide,
                          icon: Icon(Icons.event_busy),
                          label: Text('停课'),
                        ),
                      ],
                      selected: {_kind},
                      onSelectionChanged: (values) =>
                          setState(() => _kind = values.single),
                    ),
                    const SizedBox(height: 16),
                    if (_kind != _OverrideKind.add) ...[
                      DropdownButtonFormField<ScheduleCourse>(
                        initialValue: _matchCourse,
                        decoration: const InputDecoration(
                          labelText: '要调整的课程',
                          prefixIcon: Icon(Icons.menu_book),
                        ),
                        items: [
                          for (final item in _candidates)
                            DropdownMenuItem(
                              value: item,
                              child: Text(
                                '${item.name}（${_weekdayChar(item.weekday)} ${_sectionLabel(item.startSection)}）',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _matchCourse = value;
                            // 调整类型：选中课程后自动带出原信息（改星期即可实现「调到另一天」）
                            if (_kind == _OverrideKind.replace &&
                                value != null) {
                              _nameCtrl.text = value.name;
                              _classroomCtrl.text = value.classroom ?? '';
                              _teacherCtrl.text = value.teacher ?? '';
                              _weeksCtrl.text = value.weeks ?? '';
                              _weekday = value.weekday;
                              _startSection = value.startSection;
                              _endSection = value.endSection;
                            }
                          });
                        },
                      ),
                      if (_kind == _OverrideKind.replace &&
                          _matchCourse != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '原时间：${_courseTimeText(_matchCourse!)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 14),
                    ],
                    if (_kind != _OverrideKind.hide) ...[
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: '课程名称',
                          prefixIcon: Icon(Icons.edit),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: _weekday,
                              decoration: const InputDecoration(
                                labelText: '星期',
                                prefixIcon: Icon(Icons.today),
                              ),
                              items: [
                                for (var day = 1; day <= 7; day++)
                                  DropdownMenuItem(
                                    value: day,
                                    child: Text('周${'一二三四五六日'[day - 1]}'),
                                  ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _weekday = value),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: _startSection,
                              decoration: const InputDecoration(
                                labelText: '开始节次',
                                prefixIcon: Icon(Icons.play_arrow),
                              ),
                              items: [
                                for (var section = 1; section <= 16; section++)
                                  DropdownMenuItem(
                                    value: section,
                                    child: Text('第$section节'),
                                  ),
                              ],
                              onChanged: (value) => setState(() {
                                _startSection = value;
                                if (_endSection == null || _endSection! < (value ?? 0)) {
                                  _endSection = value;
                                }
                              }),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: _endSection,
                              decoration: const InputDecoration(
                                labelText: '结束节次',
                                prefixIcon: Icon(Icons.stop),
                              ),
                              items: [
                                for (var section = 1; section <= 16; section++)
                                  DropdownMenuItem(
                                    value: section,
                                    child: Text('第$section节'),
                                  ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _endSection = value),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _classroomCtrl,
                              decoration: const InputDecoration(
                                labelText: '教室',
                                prefixIcon: Icon(Icons.room),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _teacherCtrl,
                        decoration: const InputDecoration(
                          labelText: '教师（可选）',
                          prefixIcon: Icon(Icons.person),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _weeksCtrl,
                      decoration: InputDecoration(
                        labelText: _kind == _OverrideKind.hide
                            ? '停课周次（留空=全部周）'
                            : '周次（可选）',
                        hintText:
                            '如 8、1-16、1-16周(单)；留空表示全部周',
                        prefixIcon: const Icon(Icons.date_range),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _noteCtrl,
                      decoration: const InputDecoration(
                        labelText: '备注（可选）',
                        prefixIcon: Icon(Icons.notes),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.check),
                      label: const Text('保存'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _weekdayChar(int? weekday) {
    if (weekday == null || weekday < 1 || weekday > 7) return '星期?';
    return '周${'一二三四五六日'[weekday - 1]}';
  }

  String _sectionLabel(int? section) {
    if (section == null) return '节次?';
    return '第$section节';
  }
}

/// 把某一整天的课程调至另一天（节次/教室/教师/周次保持不变）。
///
/// [existing] 非空时表示被调课程本身是本地条目，直接改其日期；
/// [presetWeekday] 是源课程当前星期，从选项中排除。
Future<void> showMoveToDaySheet(
  BuildContext context, {
  required ScheduleCourse course,
  required ScheduleOverride? existing,
  required Future<void> Function(ScheduleOverride override) onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _MoveToDaySheet(
      course: course,
      existing: existing,
      onSave: onSave,
    ),
  );
}

class _MoveToDaySheet extends StatefulWidget {
  const _MoveToDaySheet({
    required this.course,
    required this.existing,
    required this.onSave,
  });

  final ScheduleCourse course;
  final ScheduleOverride? existing;
  final Future<void> Function(ScheduleOverride override) onSave;

  @override
  State<_MoveToDaySheet> createState() => _MoveToDaySheetState();
}

class _MoveToDaySheetState extends State<_MoveToDaySheet> {
  int? _targetWeekday;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sourceWeekday = widget.course.weekday;
    final course = widget.course;
    final start = course.startSection;
    final end = course.endSection ?? start;
    final sectionText =
        start == null ? '节次待定' : '第$start-${(end != null && end >= start) ? end : start}节';
    final metaParts = [
      if (sourceWeekday != null && sourceWeekday >= 1 && sourceWeekday <= 7)
        '周${'一二三四五六日'[sourceWeekday - 1]}',
      sectionText,
      if (_clean(course.classroom) != null) _clean(course.classroom)!,
      if (_clean(course.teacher) != null) _clean(course.teacher)!,
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color:
                        colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  Text(
                    '调到另一天',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    course.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    metaParts.join(' · '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int?>(
                    initialValue: _targetWeekday,
                    decoration: const InputDecoration(
                      labelText: '调到星期',
                      prefixIcon: Icon(Icons.event),
                      helperText: '节次、教室、教师保持不变',
                    ),
                    items: [
                      for (var day = 1; day <= 7; day++)
                        if (day != sourceWeekday)
                          DropdownMenuItem(
                            value: day,
                            child: Text('周${'一二三四五六日'[day - 1]}'),
                          ),
                    ],
                    onChanged: (value) =>
                        setState(() => _targetWeekday = value),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      if (_targetWeekday == null) {
                        messenger?.showSnackBar(
                            const SnackBar(content: Text('请选择要调到星期几')));
                        return;
                      }
                      final override = buildMoveToDayOverride(
                        course: widget.course,
                        targetWeekday: _targetWeekday!,
                        existing: widget.existing,
                      );
                      Navigator.pop(context);
                      widget.onSave(override);
                    },
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('确认调整'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String? _clean(String? value) {
    final text = value?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}
