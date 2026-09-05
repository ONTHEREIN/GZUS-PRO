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

enum _LeaveStep { materials, courses, ready }

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
  final List<PickedAttachment> _attachments = [];
  List<PickedAttachment> _generatedAttachments = const [];
  LeavePreviewResponse? _preview;
  LeaveFillResponse? _fillResult;
  List<Map<String, dynamic>>? _scheduleCourses;
  final Map<String, StaffCandidateItem> _teacherSelections = {};
  final Map<String, List<StaffCandidateItem>> _teacherSearchResults = {};
  _LeaveStep _step = _LeaveStep.materials;
  int _draftRevision = 0;
  String? _error;
  bool _loadingPreview = false;
  bool _filling = false;
  String? _searchingTeacher;

  @override
  void initState() {
    super.initState();
    final today = dateText(DateTime.now());
    _startController = TextEditingController(text: today);
    _endController = TextEditingController(text: today);
    _startController.addListener(_invalidateLeaveResult);
    _endController.addListener(_invalidateLeaveResult);
    _reasonController.addListener(_invalidateLeaveResult);
  }

  @override
  void dispose() {
    _startController.removeListener(_invalidateLeaveResult);
    _endController.removeListener(_invalidateLeaveResult);
    _reasonController.removeListener(_invalidateLeaveResult);
    _startController.dispose();
    _endController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '自动请假',
      icon: Icons.fact_check,
      expandChild: true,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _LeaveStepIndicator(step: _step),
          const SizedBox(height: 12),
          if (_error != null) ...[
            _LeaveErrorMessage(message: _error!),
            const SizedBox(height: 12),
          ],
          switch (_step) {
            _LeaveStep.materials => _buildMaterialsStep(),
            _LeaveStep.courses => _buildCoursesStep(),
            _LeaveStep.ready => _buildReadyStep(),
          },
        ],
      ),
    );
  }

  Widget _buildMaterialsStep() {
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepHeading(
            title: '填写请假材料',
            description: '选择请假时间，填写理由并添加证明图片。',
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final dateWidth = compact ? double.infinity : 180.0;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
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
                    width: compact ? double.infinity : 300,
                    child: TextField(
                      controller: _reasonController,
                      decoration: const InputDecoration(
                        labelText: '请假理由',
                        prefixIcon: Icon(Icons.edit_note, size: 18),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Semantics(
            button: true,
            label: _attachments.isEmpty
                ? '选择请假证明图片，最多 $leaveAttachmentMaximumCount 张'
                : '添加请假证明图片，当前 ${_attachments.length} 张，最多 $leaveAttachmentMaximumCount 张',
            child: OutlinedButton(
              onPressed: _chooseAttachments,
              child: IconLabel(
                icon: Icons.image,
                label: _attachments.isEmpty
                    ? '选择证明图片'
                    : '添加图片（${_attachments.length}/$leaveAttachmentMaximumCount）',
              ),
            ),
          ),
          if (_attachments.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final attachment in _attachments)
                  Semantics(
                    label:
                        '附件 ${attachment.name}，${_attachmentSizeText(attachment.bytes.length)}，可删除',
                    child: InputChip(
                      avatar: const Icon(Icons.image_outlined, size: 18),
                      label: Text(
                        '${attachment.name}（${_attachmentSizeText(attachment.bytes.length)}）',
                      ),
                      onDeleted: () => _removeAttachment(attachment),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: '下一步，匹配受影响课程',
            child: FilledButton(
              onPressed: _loadingPreview ? null : _continueToCourses,
              child: IconLabel(
                icon: Icons.search,
                label: _loadingPreview ? '匹配中...' : '下一步：匹配课程',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoursesStep() {
    final preview = _preview;
    if (preview == null) {
      return _LeaveStepEmptyState(
        title: '尚未匹配课程',
        message: '请返回上一步填写材料后重新匹配。',
        actionLabel: '返回填写材料',
        onAction: _backToMaterials,
      );
    }
    if (preview.items.isEmpty) {
      return _LeaveStepEmptyState(
        title: '没有匹配课程',
        message: '该时间段没有匹配到课程，可返回修改日期后重试。',
        actionLabel: '重新匹配',
        onAction: _continueToCourses,
        secondaryActionLabel: '返回上一步',
        onSecondaryAction: _backToMaterials,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccentPanel(
          child: _StepHeading(
            title: '影响 ${preview.items.length} 门课',
            description: preview.hasMissingFields
                ? '请补全缺失的课程资料后，再重新匹配。'
                : '请核对课程和任课教师，再生成请假单。',
          ),
        ),
        const SizedBox(height: 10),
        for (final item in preview.items) ...[
          _LeaveCourseTile(item: item),
          const SizedBox(height: 10),
        ],
        if (preview.hasMissingFields) ...[
          const _LeaveErrorMessage(message: '存在课程字段缺失，暂不能生成请假单。'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _backToMaterials,
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回修改材料'),
          ),
        ] else if (_fillResult?.unmatchedTeachers.isNotEmpty ?? false) ...[
          if (_fillResult!.teacherCandidates.isNotEmpty)
            _TeacherCandidateSelector(
              result: _fillResult!,
              selections: _teacherSelections,
              searchResults: _teacherSearchResults,
              searchingTeacher: _searchingTeacher,
              confirming: _filling,
              onSelected: _selectTeacher,
              onSearch: _searchTeacher,
              onConfirm: _confirmTeacherSelections,
            )
          else
            AccentPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _StepHeading(
                    title: '无法解析任课教师经办人',
                    description: '请重新生成，或返回上一步检查请假材料。',
                  ),
                  const SizedBox(height: 10),
                  _LeaveErrorMessage(message: _fillResult!.message),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: _filling ? null : _fillLeave,
                    child: const Text('重新生成请假单'),
                  ),
                ],
              ),
            ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _backToMaterials,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('上一步'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Semantics(
                  button: true,
                  label: '确认课程并生成请假单',
                  child: FilledButton(
                    onPressed: _filling ? null : _fillLeave,
                    child: IconLabel(
                      icon: Icons.auto_fix_high,
                      label: _filling ? '生成中...' : '确认并生成请假单',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildReadyStep() {
    final result = _fillResult;
    if (result == null || result.unmatchedTeachers.isNotEmpty) {
      return _LeaveStepEmptyState(
        title: '请先生成请假单',
        message: '请返回课程核对步骤完成经办人确认。',
        actionLabel: '返回课程核对',
        onAction: _backToCourses,
      );
    }
    return _LeaveReadyCard(
      result: result,
      api: widget.api,
      attachments: _generatedAttachments,
      onBack: _backToCourses,
    );
  }

  Future<void> _chooseAttachments() async {
    final picked = await pickLeaveAttachments();
    if (!mounted || picked.isEmpty) return;
    final nextAttachments = [..._attachments, ...picked];
    final validationError = validateLeaveAttachments(nextAttachments);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _attachments
        ..clear()
        ..addAll(nextAttachments);
      _draftRevision++;
      _clearGeneratedState();
    });
  }

  void _removeAttachment(PickedAttachment attachment) {
    setState(() {
      _attachments.remove(attachment);
      _draftRevision++;
      _clearGeneratedState();
    });
  }

  Future<void> _continueToCourses() async {
    final validationError = _materialsValidationError();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    final matched = await _loadPreview();
    if (matched && mounted) setState(() => _step = _LeaveStep.courses);
  }

  Future<bool> _loadPreview() async {
    final range = _parseRange();
    if (range == null) return false;
    final requestRevision = _draftRevision;
    setState(() {
      _loadingPreview = true;
      _clearGeneratedState();
      _scheduleCourses = null;
    });
    try {
      final courses =
          (await widget.api.schedule(year: widget.year, term: widget.term))
              .data
              .items
              .map((item) => item.toJson())
              .toList();
      final result = await widget.api.previewLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: mondayOf(widget.firstWeekStart),
        courses: courses,
      );
      if (!mounted || requestRevision != _draftRevision) return false;
      setState(() {
        _preview = result;
        _scheduleCourses = courses.isEmpty ? null : courses;
      });
      return true;
    } catch (exc) {
      _handleError(exc);
      return false;
    } finally {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  Future<void> _fillLeave() async {
    final range = _parseRange();
    final attachments = List<PickedAttachment>.from(_attachments);
    final validationError = _materialsValidationError();
    if (range == null || validationError != null) {
      if (validationError != null) setState(() => _error = validationError);
      return;
    }
    final requestRevision = _draftRevision;
    final teacherHandlers = _teacherSelections.entries
        .map(
          (entry) => MatchedTeacherItem(
            teacher: entry.key,
            userid: entry.value.userid,
            cnName: entry.value.cnName,
          ),
        )
        .toList();
    setState(() {
      _filling = true;
      _error = null;
      _fillResult = null;
      if (teacherHandlers.isEmpty) {
        _teacherSelections.clear();
        _teacherSearchResults.clear();
      }
    });
    try {
      final result = await widget.api.fillLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: mondayOf(widget.firstWeekStart),
        reason: _reasonController.text.trim(),
        attachments: attachments,
        teacherHandlers: teacherHandlers,
        courses: _scheduleCourses ?? const [],
      );
      if (!mounted || requestRevision != _draftRevision) return;
      setState(() {
        _fillResult = result;
        _generatedAttachments =
            List<PickedAttachment>.unmodifiable(attachments);
        if (result.unmatchedTeachers.isEmpty) _step = _LeaveStep.ready;
      });
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  void _confirmTeacherSelections() {
    final groups = _fillResult?.teacherCandidates ?? const [];
    final allSelected = groups.every(
      (group) => _teacherSelections.containsKey(group.teacher),
    );
    if (!allSelected) {
      setState(() => _error = '请为每位任课教师选择经办人');
      return;
    }
    _fillLeave();
  }

  void _selectTeacher(String teacher, StaffCandidateItem candidate) {
    setState(() => _teacherSelections[teacher] = candidate);
  }

  void _backToMaterials() {
    setState(() {
      _step = _LeaveStep.materials;
      _error = null;
    });
  }

  void _backToCourses() {
    setState(() {
      _step = _LeaveStep.courses;
      _error = null;
    });
  }

  void _invalidateLeaveResult() {
    if (!mounted) return;
    setState(() {
      _draftRevision++;
      _clearGeneratedState();
    });
  }

  void _clearGeneratedState() {
    _step = _LeaveStep.materials;
    _error = null;
    _preview = null;
    _fillResult = null;
    _generatedAttachments = const [];
    _scheduleCourses = null;
    _teacherSelections.clear();
    _teacherSearchResults.clear();
  }

  String? _materialsValidationError() {
    final rangeError = _dateRangeValidationError();
    if (rangeError != null) return rangeError;
    if (_reasonController.text.trim().isEmpty) return '请填写请假理由';
    return validateLeaveAttachments(_attachments);
  }

  Future<void> _searchTeacher(String teacher, String keyword) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) {
      setState(() => _error = '请输入经办人姓名或工号');
      return;
    }
    setState(() {
      _searchingTeacher = teacher;
      _error = null;
    });
    try {
      final results = await widget.api.searchLeaveTeachers(keyword: normalized);
      if (mounted) setState(() => _teacherSearchResults[teacher] = results);
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _searchingTeacher = null);
    }
  }

  (DateTime, DateTime)? _parseRange() {
    final start = DateTime.tryParse(_startController.text.trim());
    final end = DateTime.tryParse(_endController.text.trim());
    final error = _dateRangeValidationError();
    if (error != null || start == null || end == null) {
      setState(() => _error = error ?? '请填写正确的日期范围');
      return null;
    }
    return (start, end);
  }

  String? _dateRangeValidationError() {
    final start = DateTime.tryParse(_startController.text.trim());
    final end = DateTime.tryParse(_endController.text.trim());
    if (start == null || end == null) return '日期格式应为 YYYY-MM-DD';
    if (end.isBefore(start)) return '结束日期不能早于开始日期';
    return null;
  }

  void _handleError(Object exc) {
    if (mounted) {
      setState(
        () => _error = exc is ApiException ? exc.message : exc.toString(),
      );
    }
  }
}

class _LeaveStepIndicator extends StatelessWidget {
  const _LeaveStepIndicator({required this.step});

  final _LeaveStep step;

  @override
  Widget build(BuildContext context) {
    const labels = ['填写材料', '核对课程', '打开办事大厅'];
    final current = step.index;
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: '请假流程，第 ${current + 1} 步，共 ${labels.length} 步：${labels[current]}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++)
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (index > 0)
                          Expanded(
                            child: Container(
                              height: 2,
                              color: index <= current
                                  ? cs.primary
                                  : cs.outlineVariant,
                            ),
                          ),
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: index <= current
                                ? cs.primary
                                : cs.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: index <= current
                                  ? cs.onPrimary
                                  : cs.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (index < labels.length - 1)
                          Expanded(
                            child: Container(
                              height: 2,
                              color: index < current
                                  ? cs.primary
                                  : cs.outlineVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      labels[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: index == current
                                ? cs.primary
                                : cs.onSurfaceVariant,
                            fontWeight: index == current
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepHeading extends StatelessWidget {
  const _StepHeading({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(description,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      ],
    );
  }
}

class _LeaveErrorMessage extends StatelessWidget {
  const _LeaveErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '请假流程错误：$message',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
                child: Text(message,
                    style: TextStyle(color: cs.onErrorContainer))),
          ],
        ),
      ),
    );
  }
}

class _LeaveStepEmptyState extends StatelessWidget {
  const _LeaveStepEmptyState({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    return AccentPanel(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: EmptyState(title: title, message: message),
          ),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
          if (secondaryActionLabel != null && onSecondaryAction != null) ...[
            const SizedBox(height: 8),
            TextButton(
                onPressed: onSecondaryAction,
                child: Text(secondaryActionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.controller,
    required this.labelText,
    required this.icon,
  });

  final TextEditingController controller;
  final String labelText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$labelText，${controller.text}',
      child: TextField(
        controller: controller,
        readOnly: true,
        onTap: () => _pickDate(context),
        decoration: InputDecoration(
          labelText: labelText,
          hintText: 'YYYY-MM-DD',
          prefixIcon: Icon(icon, size: 18),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
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
    final teacher = item.teacher?.trim();
    return AccentPanel(
      child: Semantics(
        label:
            '${item.courseName}，${item.classTime}，${teacher ?? '缺少任课教师'}${item.missingFields.isEmpty ? '' : '，缺少 ${item.missingFields.join('、')}'}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(item.courseName,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                Text('缺${item.absenceCount}',
                    style: TextStyle(
                        color: cs.primary, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.schedule, size: 16),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(item.classTime,
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.person_outline, size: 16),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(
                        teacher?.isNotEmpty == true ? teacher! : '未识别任课教师',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 13))),
              ],
            ),
            if (item.missingFields.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('缺少：${item.missingFields.join('、')}',
                  style: TextStyle(color: cs.error, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TeacherCandidateSelector extends StatelessWidget {
  const _TeacherCandidateSelector({
    required this.result,
    required this.selections,
    required this.searchResults,
    required this.searchingTeacher,
    required this.confirming,
    required this.onSelected,
    required this.onSearch,
    required this.onConfirm,
  });

  final LeaveFillResponse result;
  final Map<String, StaffCandidateItem> selections;
  final Map<String, List<StaffCandidateItem>> searchResults;
  final String? searchingTeacher;
  final bool confirming;
  final void Function(String teacher, StaffCandidateItem candidate) onSelected;
  final Future<void> Function(String teacher, String keyword) onSearch;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final groups = result.teacherCandidates;
    final allSelectable = groups.every(
      (group) => (searchResults[group.teacher] ?? group.candidates).isNotEmpty,
    );
    final allSelected = allSelectable &&
        groups.every((group) => selections[group.teacher] != null);
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepHeading(
            title: '确认任课教师经办人',
            description: '系统未能自动匹配以下任课教师，请选择正确经办人。',
          ),
          const SizedBox(height: 12),
          for (final group in groups) ...[
            _TeacherSearchField(
              teacher: group.teacher,
              searching: searchingTeacher == group.teacher,
              onSearch: onSearch,
            ),
            const SizedBox(height: 8),
            if ((searchResults[group.teacher] ?? group.candidates).isEmpty)
              Text('${group.teacher}：未找到候选教师，请搜索组织架构')
            else
              Semantics(
                label: '${group.teacher} 的经办人候选列表',
                child: DropdownButtonFormField<String>(
                  initialValue: selections[group.teacher]?.userid,
                  decoration:
                      InputDecoration(labelText: '${group.teacher} 的经办人'),
                  items: [
                    for (final candidate
                        in (searchResults[group.teacher] ?? group.candidates))
                      DropdownMenuItem(
                        value: candidate.userid,
                        child: Text(candidate.folderName == null
                            ? candidate.cnName
                            : '${candidate.cnName} · ${candidate.folderName}'),
                      ),
                  ],
                  onChanged: (userid) {
                    if (userid == null) return;
                    final candidate =
                        (searchResults[group.teacher] ?? group.candidates)
                            .firstWhere((item) => item.userid == userid);
                    onSelected(group.teacher, candidate);
                  },
                ),
              ),
            const SizedBox(height: 12),
          ],
          Semantics(
            button: true,
            label: '确认经办人并生成请假单',
            child: FilledButton(
              onPressed: allSelected && !confirming ? onConfirm : null,
              child: Text(confirming ? '生成中...' : '确认经办人并生成请假单'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherSearchField extends StatefulWidget {
  const _TeacherSearchField({
    required this.teacher,
    required this.searching,
    required this.onSearch,
  });

  final String teacher;
  final bool searching;
  final Future<void> Function(String teacher, String keyword) onSearch;

  @override
  State<_TeacherSearchField> createState() => _TeacherSearchFieldState();
}

class _TeacherSearchFieldState extends State<_TeacherSearchField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.teacher);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() => widget.onSearch(widget.teacher, _controller.text);

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onSubmitted: (_) => _search(),
      decoration: InputDecoration(
        labelText: '${widget.teacher} · 搜索经办人',
        hintText: '姓名或工号',
        prefixIcon: const Icon(Icons.manage_search, size: 18),
        suffixIcon: IconButton(
          tooltip: '搜索办事大厅组织架构',
          onPressed: widget.searching ? null : _search,
          icon: widget.searching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search),
        ),
      ),
    );
  }
}

class _LeaveReadyCard extends StatelessWidget {
  const _LeaveReadyCard({
    required this.result,
    required this.api,
    required this.attachments,
    required this.onBack,
  });

  final LeaveFillResponse result;
  final ApiClient api;
  final List<PickedAttachment> attachments;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final formUrl = result.formUrl;
    final fillScript = result.fillScript?.trim();
    final combinedScript = result.combinedScript;
    final canOpen =
        formUrl != null && fillScript != null && fillScript.isNotEmpty;
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepHeading(
            title: '请假单已准备好',
            description: '打开办事大厅后，应用会将冻结的附件上传到当前请假单。',
          ),
          const SizedBox(height: 14),
          const _ReadyItem(
            icon: Icons.fact_check_outlined,
            text: '课程与经办人已填入表单数据',
          ),
          const SizedBox(height: 10),
          _ReadyItem(
              icon: Icons.upload_file_outlined,
              text: '将上传 ${attachments.length} 张附件到当前单据'),
          const SizedBox(height: 10),
          const _ReadyItem(
            icon: Icons.touch_app_outlined,
            text: '请在学校页面核对后手动点击提交',
          ),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: '打开办事大厅并上传 ${attachments.length} 张附件',
            child: FilledButton.icon(
              onPressed: canOpen
                  ? () => _openEhall(context, formUrl, fillScript)
                  : null,
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开办事大厅并上传附件'),
            ),
          ),
          if (combinedScript != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => _copyScript(context, combinedScript),
              icon: const Icon(Icons.content_copy, size: 18),
              label: const Text('复制填表脚本'),
            ),
          ],
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('返回核对课程'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEhall(
      BuildContext context, String formUrl, String fillScript) async {
    await mobile_sso.loadLibrary();
    if (!context.mounted) return;
    await mobile_sso.openAuthenticatedEhallUrl(
      context,
      formUrl,
      fillScript: fillScript,
      attachments: attachments,
      api: api,
    );
  }

  Future<void> _copyScript(BuildContext context, String script) async {
    await Clipboard.setData(ClipboardData(text: script));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('填表脚本已复制')));
    }
  }
}

class _ReadyItem extends StatelessWidget {
  const _ReadyItem({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

String _attachmentSizeText(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
