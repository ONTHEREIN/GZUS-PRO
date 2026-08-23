import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api_client.dart';
import '../../leave_attachment.dart';
import '../../mobile_sso.dart' deferred as mobile_sso;
import '../../schedule_utils.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/info_tile.dart';
import '../../widgets/page_panel.dart';

class AutoLeavePage extends StatefulWidget {
  const AutoLeavePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.firstWeekStart,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int year;
  final int term;
  final DateTime firstWeekStart;
  final VoidCallback? onSessionExpired;

  @override
  State<AutoLeavePage> createState() => _AutoLeavePageState();
}

class _AutoLeavePageState extends State<AutoLeavePage> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  final _reasonController = TextEditingController();
  PickedAttachment? _attachment;
  LeavePreviewResponse? _preview;
  LeaveFillResponse? _fillResult;
  List<Map<String, dynamic>>? _scheduleCourses;
  final Map<String, StaffCandidateItem> _teacherSelections = {};
  String? _error;
  bool _loadingPreview = false;
  bool _filling = false;

  @override
  void initState() {
    super.initState();
    final today = dateText(DateTime.now());
    _startController = TextEditingController(text: today);
    _endController = TextEditingController(text: today);
    _startController.addListener(_refreshLeaveFormState);
    _endController.addListener(_refreshLeaveFormState);
    _reasonController.addListener(_refreshLeaveFormState);
  }

  @override
  void dispose() {
    _startController.removeListener(_refreshLeaveFormState);
    _endController.removeListener(_refreshLeaveFormState);
    _reasonController.removeListener(_refreshLeaveFormState);
    _startController.dispose();
    _endController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final missing = preview?.hasMissingFields ?? false;
    return PagePanel(
      title: '自动请假',
      icon: Icons.fact_check,
      expandChild: true,
      child: RefreshIndicator(
        onRefresh: _loadPreview,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AccentPanel(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 620;
                  final dateWidth = compact ? double.infinity : 160.0;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: dateWidth,
                        child: _DatePickerField(
                          controller: _startController,
                          labelText: '开始日期',
                          icon: Icons.event,
                        ),
                      ),
                      SizedBox(
                        width: dateWidth,
                        child: _DatePickerField(
                          controller: _endController,
                          labelText: '结束日期',
                          icon: Icons.event_available,
                        ),
                      ),
                      SizedBox(
                        width: compact ? double.infinity : 260,
                        child: TextField(
                          controller: _reasonController,
                          decoration: const InputDecoration(
                            labelText: '请假理由',
                            prefixIcon: Icon(Icons.edit_note, size: 18),
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _chooseAttachment,
                        child: IconLabel(
                          icon: Icons.image,
                          label: _attachment?.name ?? '选择图片',
                        ),
                      ),
                      FilledButton(
                        onPressed: _loadingPreview ? null : _loadPreview,
                        child: IconLabel(
                          icon: Icons.search,
                          label: _loadingPreview ? '匹配中...' : '匹配课程',
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: preview == null ||
                                missing ||
                                _attachment == null ||
                                _reasonController.text.trim().isEmpty ||
                                _filling
                            ? null
                            : _fillLeave,
                        child: IconLabel(
                          icon: Icons.auto_fix_high,
                          label: _filling ? '生成中...' : '生成请假单',
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_fillResult != null) ...[
              const SizedBox(height: 10),
              _LeaveResultBanner(
                result: _fillResult!,
                api: widget.api,
                attachment: _attachment,
              ),
              if (_fillResult!.teacherCandidates.isNotEmpty) ...[
                const SizedBox(height: 10),
                _TeacherCandidateSelector(
                  result: _fillResult!,
                  selections: _teacherSelections,
                  confirming: _filling,
                  onSelected: (teacher, candidate) {
                    setState(() => _teacherSelections[teacher] = candidate);
                  },
                  onConfirm: () => _fillLeave(useTeacherSelections: true),
                ),
              ],
            ],
            const SizedBox(height: 12),
            if (preview == null)
              const SizedBox(
                height: 260,
                child: EmptyState(message: '填写信息后匹配受影响课程'),
              )
            else if (preview.items.isEmpty)
              const SizedBox(
                height: 260,
                child: EmptyState(message: '该时间段没有匹配到课程'),
              )
            else
              for (var i = 0; i < preview.items.length; i++) ...[
                _LeaveCourseTile(item: preview.items[i]),
                if (i != preview.items.length - 1) const SizedBox(height: 10),
              ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseAttachment() async {
    final picked = await pickLeaveAttachment();
    if (!mounted || picked == null) return;
    setState(() => _attachment = picked);
  }

  Future<void> _loadPreview() async {
    final range = _parseRange();
    if (range == null) return;
    setState(() {
      _loadingPreview = true;
      _error = null;
      _fillResult = null;
      _scheduleCourses = null;
      _teacherSelections.clear();
    });
    try {
      List<Map<String, dynamic>> courses = const [];
      try {
        courses = (await widget.api.schedule(
          year: widget.year,
          term: widget.term,
        ))
            .data
            .raw;
      } catch (_) {
        courses = const [];
      }
      final result = await widget.api.previewLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: mondayOf(widget.firstWeekStart),
        courses: courses,
      );
      if (mounted) {
        setState(() {
          _preview = result;
          _scheduleCourses = courses.isEmpty ? null : courses;
        });
      }
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  Future<void> _fillLeave({bool useTeacherSelections = false}) async {
    final range = _parseRange();
    final attachment = _attachment;
    if (range == null || attachment == null) return;
    final teacherHandlers = useTeacherSelections
        ? _teacherSelections.entries
            .map(
              (entry) => MatchedTeacherItem(
                teacher: entry.key,
                userid: entry.value.userid,
                cnName: entry.value.cnName,
              ),
            )
            .toList()
        : const <MatchedTeacherItem>[];
    setState(() {
      _filling = true;
      _error = null;
      _fillResult = null;
      if (!useTeacherSelections) _teacherSelections.clear();
    });
    try {
      final result = await widget.api.fillLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: mondayOf(widget.firstWeekStart),
        reason: _reasonController.text.trim(),
        attachmentName: attachment.name,
        attachmentBytes: attachment.bytes,
        teacherHandlers: teacherHandlers,
        courses: _scheduleCourses ?? const [],
      );
      if (mounted) setState(() => _fillResult = result);
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  void _refreshLeaveFormState() {
    if (mounted) setState(() {});
  }

  (DateTime, DateTime)? _parseRange() {
    final start = DateTime.tryParse(_startController.text.trim());
    final end = DateTime.tryParse(_endController.text.trim());
    if (start == null || end == null) {
      setState(() => _error = '日期格式应为 YYYY-MM-DD');
      return null;
    }
    if (end.isBefore(start)) {
      setState(() => _error = '结束日期不能早于开始日期');
      return null;
    }
    return (start, end);
  }

  void _handleError(Object exc) {
    // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
    if (mounted) {
      setState(
          () => _error = exc is ApiException ? exc.message : exc.toString());
    }
  }
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.controller,
    this.labelText,
    this.icon = Icons.calendar_today,
  });

  final TextEditingController controller;
  final String? labelText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      onTap: () => _pickDate(context),
      decoration: InputDecoration(
        labelText: labelText,
        hintText: 'YYYY-MM-DD',
        prefixIcon: Icon(icon, size: 18),
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 6, 1, 1);
    final lastDate = DateTime(now.year + 6, 12, 31);
    final parsed = DateTime.tryParse(controller.text.trim());
    final initialDate = _boundedDate(parsed ?? now, firstDate, lastDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked != null) controller.text = dateText(picked);
  }

  DateTime _boundedDate(DateTime value, DateTime firstDate, DateTime lastDate) {
    if (value.isBefore(firstDate)) return firstDate;
    if (value.isAfter(lastDate)) return lastDate;
    return value;
  }
}

class _LeaveCourseTile extends StatelessWidget {
  const _LeaveCourseTile({required this.item});

  final LeaveCourseItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final missing = item.missingFields.isNotEmpty;
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.courseName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '缺${item.absenceCount}',
                style:
                    TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (item.teacher != null)
                _InfoChip(icon: Icons.person, text: item.teacher!),
              if (item.courseCode != null)
                _InfoChip(icon: Icons.tag, text: item.courseCode!),
              if (item.teachingClassCode != null)
                _InfoChip(icon: Icons.groups, text: item.teachingClassCode!),
              if (item.courseNature != null)
                _InfoChip(icon: Icons.category, text: item.courseNature!),
              if (item.credit != null)
                _InfoChip(icon: Icons.star, text: '${item.credit}学分'),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.classTime,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          if (missing) ...[
            const SizedBox(height: 8),
            Text(
              '缺少：${item.missingFields.join('、')}',
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeacherCandidateSelector extends StatelessWidget {
  const _TeacherCandidateSelector({
    required this.result,
    required this.selections,
    required this.confirming,
    required this.onSelected,
    required this.onConfirm,
  });

  final LeaveFillResponse result;
  final Map<String, StaffCandidateItem> selections;
  final bool confirming;
  final void Function(String teacher, StaffCandidateItem candidate) onSelected;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final groups = result.teacherCandidates;
    final allSelectable = groups.every((group) => group.candidates.isNotEmpty);
    final allSelected = allSelectable &&
        groups.every((group) => selections[group.teacher] != null);
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '请选择任课教师经办人',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final group in groups) ...[
            if (group.candidates.isEmpty)
              Text('${group.teacher}：未找到候选教师')
            else
              DropdownButtonFormField<String>(
                initialValue: selections[group.teacher]?.userid,
                decoration: InputDecoration(labelText: group.teacher),
                items: [
                  for (final candidate in group.candidates)
                    DropdownMenuItem(
                      value: candidate.userid,
                      child: Text(
                        candidate.folderName == null
                            ? candidate.cnName
                            : '${candidate.cnName} · ${candidate.folderName}',
                      ),
                    ),
                ],
                onChanged: (userid) {
                  if (userid == null) return;
                  final candidate = group.candidates.firstWhere(
                    (item) => item.userid == userid,
                  );
                  onSelected(group.teacher, candidate);
                },
              ),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: allSelected && !confirming ? onConfirm : null,
              child: Text(confirming ? '生成中...' : '生成经办人脚本'),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaveResultBanner extends StatelessWidget {
  const _LeaveResultBanner({
    required this.result,
    required this.api,
    required this.attachment,
  });

  final LeaveFillResponse result;
  final ApiClient api;
  final PickedAttachment? attachment;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = result.status == 'filled';
    final script =
        result.unmatchedTeachers.isEmpty ? result.combinedScript : null;
    return AccentPanel(
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.info,
              color: ok ? cs.primary : cs.tertiary),
          const SizedBox(width: 10),
          Expanded(child: Text(result.message)),
          if (script != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: script));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('填表脚本已复制')),
                  );
                }
              },
              child: const Text('复制脚本'),
            ),
          if (result.formUrl != null)
            TextButton(
              onPressed: () async {
                await mobile_sso.loadLibrary();
                if (!context.mounted) return;
                await mobile_sso.openAuthenticatedEhallUrl(
                  context,
                  result.formUrl!,
                  fillScript: script,
                  api: api,
                  attachmentName: attachment?.name,
                  attachmentBytes: attachment?.bytes,
                );
              },
              child: Text(script == null ? '打开' : '打开并填到提交前'),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(text),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
