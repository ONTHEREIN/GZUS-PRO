import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../app_logger.dart';
import '../../gzus_design.dart';
import '../../leave_attachment_models.dart';
import '../../widgets/floating_page_scaffold.dart';

const _feedbackAttachmentMaximumCount = 5;
const _feedbackAttachmentMaximumBytes = 6 * 1024 * 1024;

/// 用户反馈页：提交 Bug 或使用建议，并自动附加客户端诊断日志。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, required this.api});

  final ApiClient api;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _contactController = TextEditingController();
  final List<PickedAttachment> _attachments = <PickedAttachment>[];
  String _category = 'bug';
  bool _submitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.any,
      );
      if (result == null || !mounted) return;

      final picked = <PickedAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          throw StateError('无法读取附件「${file.name}」，请重新选择文件');
        }
        picked.add(PickedAttachment(name: file.name, bytes: bytes));
      }
      final combined = [..._attachments, ...picked];
      final validation = _validateAttachments(combined);
      if (validation != null) {
        throw ArgumentError(validation);
      }
      setState(() => _attachments.addAll(picked));
      AppLogger.info('反馈附件已选择：count=${picked.length}');
    } catch (error, stackTrace) {
      AppLogger.error('选择反馈附件失败', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择附件失败：$error')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final attachmentError = _validateAttachments(_attachments);
    if (attachmentError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(attachmentError)),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final response = await widget.api.submitFeedback(
        category: _category,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        contact: _contactController.text.trim().isEmpty
            ? null
            : _contactController.text.trim(),
        clientLogs: AppLogger.snapshot(),
        attachments: [
          for (final attachment in _attachments)
            {
              'name': attachment.name,
              'mimeType': _mimeTypeOf(attachment.name),
              'contentBase64': base64Encode(attachment.bytes),
            },
        ],
      );
      AppLogger.info('反馈工单提交成功：id=${response['id']}');
      if (!mounted) return;
      await _showSubmittedDialog(response['id']?.toString() ?? '-');
      if (!mounted) return;
      _titleController.clear();
      _descriptionController.clear();
      _contactController.clear();
      setState(() => _attachments.clear());
    } catch (error, stackTrace) {
      AppLogger.error('提交反馈工单失败', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showSubmittedDialog(String id) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('反馈已提交'),
        content: Text('工单编号：#$id\n感谢你的反馈，管理员会在后台查看处理。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _removeAttachment(PickedAttachment attachment) {
    setState(() => _attachments.remove(attachment));
  }

  @override
  Widget build(BuildContext context) {
    return FloatingPageScaffold(
      title: '反馈问题',
      icon: Icons.feedback_outlined,
      actions: const [],
      bottom: null,
      floatingActionButton: null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Text(
            '遇到问题或有好的想法？告诉我们。',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            '提交时会自动附上最近的客户端日志和运行环境信息，日志中不会包含密码或会话凭据。',
            style: GzusTextStyles.cardSubtitle(context),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('反馈内容',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 14),
                    SegmentedButton<String>(
                      key: const ValueKey('feedback-category-selector'),
                      segments: const [
                        ButtonSegment(
                          value: 'bug',
                          label: Text('反馈 Bug'),
                          icon: Icon(Icons.bug_report_outlined),
                        ),
                        ButtonSegment(
                          value: 'suggestion',
                          label: Text('使用建议'),
                          icon: Icon(Icons.lightbulb_outline),
                        ),
                      ],
                      selected: {_category},
                      onSelectionChanged: (selection) {
                        setState(() => _category = selection.first);
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const ValueKey('feedback-title-field'),
                      controller: _titleController,
                      maxLength: 200,
                      decoration: const InputDecoration(
                        labelText: '标题',
                        hintText: '请用一句话概括反馈',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? '请输入标题'
                              : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const ValueKey('feedback-description-field'),
                      controller: _descriptionController,
                      maxLines: 6,
                      maxLength: 20000,
                      decoration: const InputDecoration(
                        labelText: '描述',
                        hintText: '请描述发生了什么、如何复现，或具体的使用建议',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? '请输入描述'
                              : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const ValueKey('feedback-contact-field'),
                      controller: _contactController,
                      maxLength: 200,
                      decoration: const InputDecoration(
                        labelText: '联系方式（可选）',
                        hintText: '邮箱、QQ 或微信，方便管理员联系你',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildAttachmentPicker(context),
                    if (_attachments.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final attachment in _attachments)
                        _AttachmentTile(
                          attachment: attachment,
                          onRemove: () => _removeAttachment(attachment),
                        ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('feedback-submit-button'),
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send_outlined),
                        label: Text(_submitting ? '提交中…' : '提交反馈'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentPicker(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey('feedback-attachment-button'),
      onPressed: _attachments.length >= _feedbackAttachmentMaximumCount
          ? null
          : _pickAttachments,
      icon: const Icon(Icons.attach_file),
      label: Text(
        _attachments.isEmpty
            ? '添加附件（可选）'
            : '继续添加附件（${_attachments.length}/$_feedbackAttachmentMaximumCount）',
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.attachment, required this.onRemove});

  final PickedAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title:
          Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_formatBytes(attachment.bytes.length)),
      trailing: IconButton(
        tooltip: '移除附件',
        onPressed: onRemove,
        icon: const Icon(Icons.close),
      ),
    );
  }
}

String? _validateAttachments(List<PickedAttachment> attachments) {
  if (attachments.length > _feedbackAttachmentMaximumCount) {
    return '最多添加 $_feedbackAttachmentMaximumCount 个附件';
  }
  final totalBytes = attachments.fold<int>(
    0,
    (total, attachment) => total + attachment.bytes.length,
  );
  if (totalBytes > _feedbackAttachmentMaximumBytes) {
    return '附件总大小不能超过 6 MB';
  }
  return null;
}

String _mimeTypeOf(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'json' => 'application/json',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
