part of 'schedule_adjustments_page.dart';

extension _AdjustmentEditor on _ScheduleAdjustmentsPageState {
  String _identity(ScheduleOccurrence o) =>
      o.course.raw['groupId'] as String? ??
      o.occurrenceKey
          .split('->')
          .first
          .replaceFirst(RegExp(r'^course:\d{4}-\d{2}-\d{2}:'), '')
          .replaceFirst(RegExp(r'(:\d+-\d+)+$'), '');
  List<ScheduleOccurrence> get _selected =>
      _courses.where((o) => _keys.contains(o.occurrenceKey)).toList()
        ..sort((a, b) => a.date.compareTo(b.date) != 0
            ? a.date.compareTo(b.date)
            : a.course.startSection!.compareTo(b.course.startSection!));
  Map<String, List<ScheduleOccurrence>> get _groups {
    final result = <String, List<ScheduleOccurrence>>{};
    for (final occurrence in _courses) {
      final id = _identity(occurrence);
      if (_keys.contains(occurrence.occurrenceKey) ||
          _rangeModes.containsKey(id)) {
        result.putIfAbsent(id, () => []);
        if (_keys.contains(occurrence.occurrenceKey)) {
          result[id]!.add(occurrence);
        }
      }
    }
    return result;
  }

  List<ScheduleOccurrence> _onDay(DateTime date) => _courses
      .where((o) => dateText(o.date) == dateText(date))
      .toList()
    ..sort((a, b) => a.course.startSection!.compareTo(b.course.startSection!));
  String _dayLabel(DateTime date) => '${dateText(date)} 周${[
        '一',
        '二',
        '三',
        '四',
        '五',
        '六',
        '日'
      ][date.weekday - 1]} · 第${weekFromDate(widget.firstWeekStart, date)}周';
  AdjustmentPair _forCourse(ScheduleOccurrence o, DateTime date) {
    final old = _settings[o.occurrenceKey], group = _identity(o);
    final start = old?.sourceStart ?? o.course.startSection!,
        end = old?.sourceEnd ?? o.course.endSection ?? start;
    return AdjustmentPair(
        sourceDate: o.date,
        targetDate: date,
        sourceStart: start,
        sourceEnd: end,
        targetStart: old?.targetStart ??
            (_operation == 'course' ? _targetStarts[group] : null) ??
            start,
        sourceKeys: [o.occurrenceKey],
        action: old?.action ?? 'choose');
  }

  List<AdjustmentPair> _pairs() {
    if (_operation == 'day' || _operation == 'dayCover') {
      final a = [..._sources]..sort(), b = [..._targets]..sort();
      if (a.isEmpty || a.length != b.length) throw StateError('请选择数量相同的两组日期');
      return [
        for (var i = 0; i < a.length; i++)
          AdjustmentPair(
              sourceDate: a[i],
              targetDate: b[i],
              sourceStart: 1,
              sourceEnd: 16,
              targetStart: 1,
              sourceKeys: _operation == 'dayCover'
                  ? _onDay(a[i]).map((o) => o.occurrenceKey).toList()
                  : const [],
              action: _operation == 'dayCover' ? 'replace' : 'swap')
      ];
    }
    if (_selected.isEmpty) throw StateError('请选择至少一次课程');
    if (_operation == 'partialDay' || _operation == 'dayCover') {
      final a = _selected.map((o) => dateText(o.date)).toSet().toList()..sort();
      final b = [..._targets]..sort();
      if (a.length != b.length) throw StateError('为每个有选中课程的来源日期选择一个目标日期');
      return [
        for (final o in _selected) _forCourse(o, b[a.indexOf(dateText(o.date))])
      ];
    }
    return [
      for (final group in _groups.entries)
        ..._groupPairs(group.key, group.value)
    ];
  }

  List<AdjustmentPair> _groupPairs(String id, List<ScheduleOccurrence> rows) {
    final mode = _targetModes[id] ?? 'uniform', dates = _groupTargets[id] ?? [];
    if (rows.isEmpty) return [];
    if (mode == 'dates' && dates.length != rows.length) {
      throw StateError('${rows.first.course.name}的目标日期数量需要与来源次数一致');
    }
    final sorted = [...dates]..sort();
    return [
      for (var i = 0; i < rows.length; i++)
        _forCourse(
            rows[i],
            mode == 'individual' && _settings[rows[i].occurrenceKey] != null
                ? _settings[rows[i].occurrenceKey]!.targetDate
                : mode == 'dates'
                    ? sorted[i]
                    : mondayOf(rows[i].date).add(Duration(
                        days:
                            (_targetWeekdays[id] ?? rows[i].date.weekday) - 1)))
    ];
  }

  String? _validationError() {
    try {
      if (_keys.any((key) => !_courses.any((o) => o.occurrenceKey == key))) {
        return '部分课程已变化，请清除无效选择后重新选课';
      }
      if ((_operation == 'day' || _operation == 'dayCover') &&
          (_sources.toSet().length != _sources.length ||
              _targets.toSet().length != _targets.length ||
              _sources.any(
                  (a) => _targets.any((b) => dateText(a) == dateText(b))))) {
        return '整日调整的两组日期不能重复或交叉';
      }
      final pairs = _pairs();
      if (pairs.length > 60) return '一次最多调整60项，请减少选择';
      for (final p in pairs) {
        if (p.sourceStart > p.sourceEnd || p.targetEnd > 16) {
          return '目标结束节次超过第16节或来源区间无效，请修改';
        }
        if (dateText(p.sourceDate) == dateText(p.targetDate) &&
            p.sourceStart <= p.targetEnd &&
            p.targetStart <= p.sourceEnd) {
          return '同日来源与目标区间不能重叠，请设置新时间';
        }
        if (_operation == 'dayCover' && _onDay(p.sourceDate).isEmpty) {
          return '来源日期没有课程，无法移动整日课表';
        }
        if (_operation == 'day' &&
            _onDay(p.targetDate).isEmpty &&
            _onDay(p.sourceDate).isEmpty) {
          return '配对两侧均无课，请移除此配对';
        }
      }
      return null;
    } on StateError catch (e) {
      return e.message;
    }
  }

  AdjustmentRequest _request() => AdjustmentRequest(
      schemaVersion: 3,
      year: widget.year,
      term: widget.term,
      firstWeekStart: widget.firstWeekStart,
      operation: _operation,
      pairs: _pairs());
  void _restoreEditor(Map<String, dynamic> saved) {
    final editor = saved['editor'];
    if (editor is! Map<String, dynamic>) return;
    _keys.addAll((editor['keys'] as List).cast<String>());
    _sources
      ..clear()
      ..addAll((editor['sources'] as List).cast<String>().map(DateTime.parse));
    _targets
      ..clear()
      ..addAll((editor['targets'] as List).cast<String>().map(DateTime.parse));
    for (final e in (editor['ranges'] as Map<String, dynamic>).entries) {
      _rangeModes[e.key] = e.value as String;
    }
    for (final e in (editor['modes'] as Map<String, dynamic>).entries) {
      _targetModes[e.key] = e.value as String;
    }
    for (final e in (editor['weekdays'] as Map<String, dynamic>).entries) {
      _targetWeekdays[e.key] = e.value as int;
    }
    for (final e in (editor['starts'] as Map<String, dynamic>).entries) {
      _targetStarts[e.key] = e.value as int;
    }
    for (final e in (editor['fromWeeks'] as Map<String, dynamic>).entries) {
      _fromWeeks[e.key] = e.value as int;
    }
    for (final e in (editor['groupTargets'] as Map<String, dynamic>).entries) {
      _groupTargets[e.key] =
          (e.value as List).cast<String>().map(DateTime.parse).toList();
    }
    _screen = _operation == 'course' ? 'course' : 'day';
  }

  void _changed() {
    _preview = null;
    _clientId = '';
    _error = null;
    _refresh(() {});
    final draft = {
      'schemaVersion': 3,
      'year': widget.year,
      'term': widget.term,
      'firstWeekStart': dateText(widget.firstWeekStart),
      'operation': _operation,
      'pairs': [
        for (final o in _selected)
          (_settings[o.occurrenceKey] ?? _forCourse(o, o.date)).toBatchJson()
      ],
      'targets': _targets.map(dateText).toList(),
      'editor': {
        'keys': _keys.toList(),
        'sources': _sources.map(dateText).toList(),
        'targets': _targets.map(dateText).toList(),
        'ranges': _rangeModes,
        'modes': _targetModes,
        'weekdays': _targetWeekdays,
        'starts': _targetStarts,
        'fromWeeks': _fromWeeks,
        'groupTargets': {
          for (final e in _groupTargets.entries)
            e.key: e.value.map(dateText).toList()
        }
      }
    };
    final encoded = jsonEncode(draft);
    _draftWrite = _draftWrite.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_draftKey, encoded)) {
        throw StateError('调课草稿保存失败');
      }
    }).catchError((Object e) {
      if (mounted) _refresh(() => _error = '$e');
    });
  }

  void _switchEditor(String mode) {
    _screen = mode;
    _operation = mode;
    _courseStep = 0;
    _keys.clear();
    _sources.clear();
    _targets.clear();
    _settings.clear();
    _groupTargets.clear();
    _rangeModes.clear();
    _targetModes.clear();
    _targetWeekdays.clear();
    _targetStarts.clear();
    _fromWeeks.clear();
    _changed();
  }

  void _toggle(ScheduleOccurrence o) {
    if (!_keys.remove(o.occurrenceKey)) {
      _keys.add(o.occurrenceKey);
      if (_operation == 'course') {
        _rangeModes.putIfAbsent(_identity(o), () => 'selected');
      }
    }
    _changed();
  }

  Future<void> _chooseDates(String group) async {
    final dates = await showModalBottomSheet<List<DateTime>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ScheduleDateSelection(
            first: widget.firstWeekStart,
            selected: group == 'source' ? _sources : _targets,
            allowed: null,
            title: group == 'source' ? '选择来源日期 / A组' : '选择目标日期 / B组',
            courses: _courses));
    if (dates == null || !mounted) return;
    if (group == 'source') {
      final previous = _sources.map(dateText).toSet();
      _sources
        ..clear()
        ..addAll(dates);
      if (_operation == 'partialDay' || _operation == 'dayCover') {
        _keys.removeWhere((key) => !_courses.any((o) =>
            o.occurrenceKey == key &&
            dates.any((d) => dateText(d) == dateText(o.date))));
        for (final d in dates.where((d) => !previous.contains(dateText(d)))) {
          _keys.addAll(_onDay(d).map((o) => o.occurrenceKey));
        }
      }
    } else {
      _targets
        ..clear()
        ..addAll(dates);
    }
    _settings.clear();
    _changed();
  }

  Future<void> _chooseGroupDates(String group) async {
    final dates = await showModalBottomSheet<List<DateTime>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ScheduleDateSelection(
            first: widget.firstWeekStart,
            selected: _groupTargets[group] ?? [],
            allowed: null,
            title: '跨周目标日期',
            courses: _courses));
    if (dates == null || !mounted) return;
    _groupTargets[group] = dates;
    _changed();
  }

  void _editPair(
      AdjustmentPair p, int start, int end, int target, String action) {
    _settings[p.itemId] = AdjustmentPair(
        sourceDate: p.sourceDate,
        targetDate: p.targetDate,
        sourceStart: start,
        sourceEnd: end,
        targetStart: target,
        sourceKeys: p.sourceKeys,
        action: action);
    _changed();
  }

  Widget _summary(List<ScheduleOccurrence> rows, String title) => ExpansionTile(
          title: Text('$title · ${rows.length}次'),
          initiallyExpanded: true,
          children: [
            for (final o in rows)
              ListTile(
                  title: Text(o.course.name, maxLines: 2),
                  subtitle: Text(
                      '${_dayLabel(o.date)} · ${o.course.startSection}–${o.course.endSection}节\n${o.course.classroom ?? ''} ${o.course.teacher ?? ''}'))
          ]);

  Widget _courseSummaryCard(ScheduleOccurrence occurrence) => Card(
      margin: const EdgeInsets.symmetric(vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
                width: 5,
                height: 32,
                margin: const EdgeInsets.only(right: 14, top: 2),
                decoration: BoxDecoration(
                    color: scheduleCourseColor(occurrence.course.name),
                    borderRadius: BorderRadius.circular(4))),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(occurrence.course.name,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _summaryLine(Icons.calendar_month,
                      '第${occurrence.week}周 · ${_dayLabel(occurrence.date).split(' · ').first}'),
                  _summaryLine(
                      Icons.schedule,
                      '周${[
                        '一',
                        '二',
                        '三',
                        '四',
                        '五',
                        '六',
                        '日'
                      ][occurrence.date.weekday - 1]} 第${occurrence.course.startSection}–${occurrence.course.endSection}节'),
                  _summaryLine(Icons.place_outlined,
                      occurrence.course.classroom ?? '教室未安排'),
                  _summaryLine(Icons.person_outline,
                      occurrence.course.teacher ?? '教师未安排')
                ]))
          ])));

  Widget _summaryLine(IconData icon, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 10),
        Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyLarge))
      ]));

  List<Widget> _editorContent() {
    if (_screen == 'day') return _dayEditor();
    if (_courseStep == 0) {
      return [
        Text('${widget.year}学年 第${widget.term}学期'),
        Row(children: [
          IconButton(
              key: const ValueKey('adjustment-week-prev'),
              onPressed: _week > 1 ? () => _refresh(() => _week--) : null,
              icon: const Icon(Icons.chevron_left)),
          Expanded(
              child: DropdownButton<int>(
                  key: const ValueKey('adjustment-week-picker'),
                  value: _week,
                  isExpanded: true,
                  items: [
                    for (var w = 1; w <= 30; w++)
                      DropdownMenuItem(value: w, child: Text('第$w周'))
                  ],
                  onChanged: (w) {
                    if (w != null) _refresh(() => _week = w);
                  })),
          IconButton(
              key: const ValueKey('adjustment-week-next'),
              onPressed: _week < 30 ? () => _refresh(() => _week++) : null,
              icon: const Icon(Icons.chevron_right))
        ]),
        Text(
            '${dateText(widget.firstWeekStart.add(Duration(days: (_week - 1) * 7)))} — ${dateText(widget.firstWeekStart.add(Duration(days: (_week - 1) * 7 + 6)))}'),
        LayoutBuilder(builder: (_, constraints) {
          final grid = ScheduleSelectionWeek(
              rows: _courses.where((o) => o.week == _week).toList(),
              selected: _keys,
              firstDay:
                  widget.firstWeekStart.add(Duration(days: (_week - 1) * 7)),
              onSelect: _toggle);
          final summary = _summary(_selected,
              '已选 ${_groups.values.where((rows) => rows.isNotEmpty).length} 门教学安排');
          return constraints.maxWidth >= 1100
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: grid),
                  const SizedBox(width: 24),
                  SizedBox(width: 300, child: summary)
                ])
              : Column(children: [grid, summary]);
        })
      ];
    }
    final groups = _groups.entries.toList();
    if (groups.isEmpty) return [const Text('请返回周课表选择课程')];
    _groupIndex = _groupIndex.clamp(0, groups.length - 1);
    final group = groups[_groupIndex];
    final occurrences =
        _courses.where((o) => _identity(o) == group.key).toList();
    final summaryOccurrence =
        group.value.isNotEmpty ? group.value.first : occurrences.first;
    return [
      Text(_courseStep == 1 ? '选择要调整的周次' : '当前上课时间 → 新上课时间',
          style: Theme.of(context).textTheme.titleLarge),
      if (groups.length > 1)
        Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              IconButton(
                  key: const ValueKey('adjustment-group-prev'),
                  onPressed: _groupIndex > 0
                      ? () => _refresh(() => _groupIndex--)
                      : null,
                  icon: const Icon(Icons.chevron_left)),
              Expanded(
                  child: Center(
                      child: Text(
                          '第${_groupIndex + 1} / ${groups.length}门 · ${summaryOccurrence.course.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis))),
              IconButton(
                  key: const ValueKey('adjustment-group-next'),
                  onPressed: _groupIndex + 1 < groups.length
                      ? () => _refresh(() => _groupIndex++)
                      : null,
                  icon: const Icon(Icons.chevron_right))
            ])),
      _courseSummaryCard(summaryOccurrence),
      Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_courseStep == 1)
                      ..._rangeEditor(group.key, group.value)
                    else
                      ..._targetEditor(group.key, group.value),
                    const Divider(height: 28),
                    if (_courseStep == 1)
                      _summary(group.value, '已选课程 · ${group.value.length}次')
                    else
                      _summary(group.value, '当前上课时间 · ${group.value.length}次')
                  ]))),
      if (_courseStep == 2 && _validationError() != null)
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_validationError()!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)))
    ];
  }

  List<Widget> _rangeEditor(String id, List<ScheduleOccurrence> chosen) {
    final all = _courses.where((o) => _identity(o) == id).toList(),
        mode = _rangeModes[id] ?? 'selected';
    return [
      Text('选择要调整的周次', style: Theme.of(context).textTheme.titleMedium),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final option in [
          ('selected', '仅已选这些次'),
          ('weeks', '选择多个周次'),
          ('future', '从选定周起')
        ])
          ChoiceChip(
              key: ValueKey('adjustment-range-mode-$id-${option.$1}'),
              label: Text(option.$2),
              selected: mode == option.$1,
              onSelected: (_) {
                _rangeModes[id] = option.$1;
                if (option.$1 == 'future') {
                  final start = _fromWeeks[id] ?? _week;
                  _keys.removeAll(all.map((o) => o.occurrenceKey));
                  _keys.addAll(all
                      .where((o) => o.week >= start)
                      .map((o) => o.occurrenceKey));
                }
                _changed();
              }),
      ]),
      if (mode == 'future')
        _section(
            'adjustment-from-week-$id', '从第几周起', _fromWeeks[id] ?? _week, 1, 30,
            (w) {
          _fromWeeks[id] = w;
          _keys.removeAll(all.map((o) => o.occurrenceKey));
          _keys.addAll(
              all.where((o) => o.week >= w).map((o) => o.occurrenceKey));
          _changed();
        }),
      if (mode != 'selected') ...[
        Wrap(children: [
          TextButton(
              onPressed: () {
                _keys.addAll(all.map((o) => o.occurrenceKey));
                _changed();
              },
              child: const Text('全选可调整课程')),
          TextButton(
              onPressed: () {
                _keys.removeAll(all.map((o) => o.occurrenceKey));
                _changed();
              },
              child: const Text('清空'))
        ]),
        GridView.count(
            key: ValueKey('adjustment-scope-grid-$id'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 5,
            childAspectRatio: 1.6,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (var w = 1; w <= 30; w++)
                Builder(builder: (context) {
                  final available = all.any((o) => o.week == w);
                  final selected = all.any(
                      (o) => o.week == w && _keys.contains(o.occurrenceKey));
                  return OutlinedButton(
                      key: ValueKey('adjustment-scope-$id-$w'),
                      onPressed: available
                          ? () {
                              final keys = all
                                  .where((o) => o.week == w)
                                  .map((o) => o.occurrenceKey);
                              if (selected) {
                                _keys.removeAll(keys);
                              } else {
                                _keys.addAll(keys);
                              }
                              _changed();
                            }
                          : null,
                      style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          backgroundColor: selected
                              ? const Color(0xFFFF315A)
                              : available
                                  ? Theme.of(context).colorScheme.surface
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                          foregroundColor: selected ? Colors.white : null,
                          side: BorderSide(
                              color: selected
                                  ? const Color(0xFFFF315A)
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant)),
                      child: Text(selected ? '✓ $w' : '$w'));
                })
            ]),
        const SizedBox(height: 8),
        Text('已选 ${chosen.length} 次实际课程',
            style: Theme.of(context).textTheme.bodyMedium),
        for (final o in chosen)
          ListTile(
              dense: true,
              leading: const Icon(Icons.check_box_outlined),
              title: Text('${dateText(o.date)} · 第${o.week}周'),
              subtitle: Text('周${[
                '一',
                '二',
                '三',
                '四',
                '五',
                '六',
                '日'
              ][o.date.weekday - 1]} 第${o.course.startSection}–${o.course.endSection}节'))
      ]
    ];
  }

  List<Widget> _targetEditor(String id, List<ScheduleOccurrence> rows) {
    final mode = _targetModes[id] ?? 'uniform';
    if (rows.isEmpty) return [const Text('尚未选择课程，请返回选择调整范围')];
    return [
      Text('新上课时间', style: Theme.of(context).textTheme.titleMedium),
      Wrap(spacing: 8, children: [
        for (final option in [('uniform', '保留周次'), ('dates', '跨周日期配对')])
          ChoiceChip(
              key: ValueKey('adjustment-target-mode-$id-${option.$1}'),
              label: Text(option.$2),
              selected: mode == option.$1 ||
                  (mode == 'individual' && option.$1 == 'dates'),
              onSelected: (_) {
                _targetModes[id] = option.$1;
                for (final o in rows) {
                  _settings.remove(o.occurrenceKey);
                }
                _changed();
              })
      ]),
      if (mode == 'individual')
        const Padding(
            padding: EdgeInsets.all(8),
            child: Text('已恢复旧草稿：每次课程保留各自目标，请核对后再预览。')),
      if (mode == 'uniform') ...[
        const SizedBox(height: 8),
        const Text('目标星期'),
        Wrap(spacing: 4, children: [
          for (var d = 1; d <= 7; d++)
            ChoiceChip(
                key: ValueKey('adjustment-target-weekday-$id-$d'),
                label: Text('周${['一', '二', '三', '四', '五', '六', '日'][d - 1]}'),
                selected: (_targetWeekdays[id] ?? rows.first.date.weekday) == d,
                onSelected: (_) {
                  _targetWeekdays[id] = d;
                  for (final o in rows) {
                    _settings.remove(o.occurrenceKey);
                  }
                  _changed();
                })
        ]),
        _section('group-start-$id', '统一目标开始',
            _targetStarts[id] ?? rows.first.course.startSection!, 1, 16, (v) {
          _targetStarts[id] = v;
          for (final o in rows) {
            _settings.remove(o.occurrenceKey);
          }
          _changed();
        })
      ],
      if (mode == 'dates')
        OutlinedButton(
            onPressed: () => _chooseGroupDates(id),
            child: Text(
                '选择目标日期（${_groupTargets[id]?.length ?? 0}/${rows.length}）')),
      if (mode != 'dates' && mode != 'individual' ||
          mode == 'dates' && (_groupTargets[id]?.length ?? 0) == rows.length ||
          mode == 'individual')
        for (final p in _groupPairs(id, rows)) _pairEditor(p)
    ];
  }

  Widget _pairEditor(AdjustmentPair p) {
    final o =
        _courses.firstWhere((o) => p.sourceKeys.contains(o.occurrenceKey));
    return ExpansionTile(
        title: Text(
            '${o.course.name}\n${dateText(p.sourceDate)} ${p.sourceStart}–${p.sourceEnd}节 → ${dateText(p.targetDate)} ${p.targetStart}–${p.targetEnd}节'),
        subtitle: Text(
            _settings.containsKey(p.itemId) ? '单独设置 / 已修改' : '单独设置 · 默认整堂课'),
        children: [
          _section(
              'source-start-${p.itemId}',
              '只调整部分节次：开始',
              p.sourceStart,
              o.course.startSection!,
              p.sourceEnd,
              (v) => _editPair(p, v, p.sourceEnd, p.targetStart, 'choose')),
          _section(
              'source-end-${p.itemId}',
              '来源结束',
              p.sourceEnd,
              p.sourceStart,
              o.course.endSection ?? o.course.startSection!,
              (v) => _editPair(p, p.sourceStart, v, p.targetStart, 'choose')),
          _section('target-${p.itemId}', '目标开始', p.targetStart, 1, 16,
              (v) => _editPair(p, p.sourceStart, p.sourceEnd, v, 'choose'))
        ]);
  }

  Widget _dayCourseList(DateTime day, {required bool source}) {
    final rows = _onDay(day);
    return Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${_dayLabel(day)} · 共${rows.length}节课',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Divider(height: 24),
                  if (rows.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('当天无课')),
                  for (final o in rows)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                  width: 62,
                                  child: Text(
                                      '${o.course.startSection}–${o.course.endSection}节',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge)),
                              Container(
                                  width: 4,
                                  height: 42,
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                      color: scheduleCourseColor(o.course.name),
                                      borderRadius: BorderRadius.circular(4))),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(o.course.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    Text(
                                        '${o.course.classroom ?? ''} · ${o.course.teacher ?? ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall)
                                  ])),
                              if (source)
                                const Icon(Icons.check_circle,
                                    color: Color(0xFFFF315A), size: 22)
                            ])),
                  if (_operation == 'dayCover' && !source && rows.isNotEmpty)
                    Text('覆盖模式下，目标日这些课程将被移除',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))
                ])));
  }

  List<Widget> _dayEditor() => [
        SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'day', label: Text('整日交换')),
              ButtonSegment(value: 'dayCover', label: Text('整日覆盖'))
            ],
            selected: {
              _operation
            },
            onSelectionChanged: (values) {
              _operation = values.single;
              _settings.clear();
              _keys.clear();
              _changed();
            }),
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_operation == 'day'
                ? '交换两天的整张课表，课程节次保持原样。'
                : '把来源当天所有课程移到目标日期，目标当天原有课程会被覆盖。')),
        ListTile(
            key: const ValueKey('adjustment-source-calendar'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            tileColor: Theme.of(context).colorScheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.calendar_month),
            title: const Text('当前上课时间'),
            subtitle: Text('选择来源日期（${_sources.length}天）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _chooseDates('source')),
        for (final day in [..._sources]..sort())
          _dayCourseList(day, source: true),
        const SizedBox(height: 12),
        ListTile(
            key: const ValueKey('adjustment-target-calendar'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            tileColor: Theme.of(context).colorScheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.schedule),
            title: const Text('新上课时间'),
            subtitle: Text('选择目标日期（${_targets.length}天）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _chooseDates('target')),
        for (final day in [..._targets]..sort())
          _dayCourseList(day, source: false),
        if (_validationError() != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_validationError()!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_validationError() == null)
          for (final p in _pairs())
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                        '${_dayLabel(p.sourceDate)} ${_operation == 'day' ? '↔' : '→'} ${_dayLabel(p.targetDate)} · 来源${_onDay(p.sourceDate).length}门 / 目标${_onDay(p.targetDate).length}门')))
      ];
}
