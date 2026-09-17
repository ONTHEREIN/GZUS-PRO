import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/floating_page_scaffold.dart';

/// 管理后台反馈工单列表，可点击查看完整描述、日志和附件。
class FeedbackTab extends StatefulWidget {
  const FeedbackTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<FeedbackTab> createState() => _FeedbackTabState();
}

class _FeedbackTabState extends State<FeedbackTab> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminFeedback();
  }

  void _refresh() {
    setState(() => _future = widget.api.adminFeedback());
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final id = item['id'];
    if (id is! int) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AdminFeedbackDetailPage(
          api: widget.api,
          feedbackId: id,
          summary: item,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await _future;
      },
      child: AsyncPanel<Map<String, dynamic>>(
        future: _future,
        emptyMessage: '暂无反馈工单',
        builder: (data) {
          final items = (data['items'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Text('反馈工单', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  StatusPill(
                    label: '${data['total'] ?? items.length} 条',
                    color: GzusColors.blue,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('暂无反馈工单')),
                ),
              for (final item in items) ...[
                _FeedbackListCard(
                  item: item,
                  onTap: () => _openDetail(item),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _FeedbackListCard extends StatelessWidget {
  const _FeedbackListCard({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final category = item['category']?.toString() ?? 'bug';
    final attachmentCount =
        (item['attachments'] as List<dynamic>? ?? const []).length;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          category == 'suggestion'
              ? Icons.lightbulb_outline
              : Icons.bug_report_outlined,
          color: category == 'suggestion' ? GzusColors.amber : GzusColors.red,
        ),
        title: Text(
          '#${item['id'] ?? '-'}  ${item['title'] ?? '未命名反馈'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${category == 'suggestion' ? '使用建议' : '反馈 Bug'} · '
          '${item['studentId'] ?? '-'} · ${_formatDate(item['createdAt'])}\n'
          '${item['description'] ?? ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const StatusPill(label: '待处理', color: GzusColors.amber),
            if (attachmentCount > 0) ...[
              const SizedBox(height: 6),
              const Icon(Icons.attach_file, size: 16, color: GzusColors.muted),
            ],
          ],
        ),
      ),
    );
  }
}

/// 反馈工单详情页。
class AdminFeedbackDetailPage extends StatefulWidget {
  const AdminFeedbackDetailPage({
    super.key,
    required this.api,
    required this.feedbackId,
    required this.summary,
  });

  final ApiClient api;
  final int feedbackId;
  final Map<String, dynamic> summary;

  @override
  State<AdminFeedbackDetailPage> createState() =>
      _AdminFeedbackDetailPageState();
}

class _AdminFeedbackDetailPageState extends State<AdminFeedbackDetailPage> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminFeedbackDetail(widget.feedbackId);
  }

  @override
  Widget build(BuildContext context) {
    return FloatingPageScaffold(
      title: '反馈工单 #${widget.feedbackId}',
      icon: Icons.feedback_outlined,
      actions: const [],
      bottom: null,
      floatingActionButton: null,
      body: PageRefresh(
        onRefresh: () async {
          setState(() =>
              _future = widget.api.adminFeedbackDetail(widget.feedbackId));
          await _future;
        },
        child: AsyncPanel<Map<String, dynamic>>(
          future: _future,
          emptyMessage: '工单不存在',
          builder: (data) => _FeedbackDetailView(data: data),
        ),
      ),
    );
  }
}

class _FeedbackDetailView extends StatelessWidget {
  const _FeedbackDetailView({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final category = data['category']?.toString() ?? 'bug';
    final attachments = (data['attachments'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusPill(
                      label: category == 'suggestion' ? '使用建议' : '反馈 Bug',
                      color: category == 'suggestion'
                          ? GzusColors.amber
                          : GzusColors.red,
                    ),
                    const SizedBox(width: 8),
                    const StatusPill(label: '待处理', color: GzusColors.blue),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  data['title']?.toString() ?? '未命名反馈',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                _DetailRow(
                    label: '提交人',
                    value:
                        '${data['studentName'] ?? '-'} (${data['studentId'] ?? '-'})'),
                _DetailRow(
                    label: '联系方式',
                    value: data['contact']?.toString().trim().isNotEmpty == true
                        ? data['contact'].toString()
                        : '未填写'),
                _DetailRow(
                    label: '提交时间', value: _formatDate(data['createdAt'])),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _DetailSection(
          title: '问题描述',
          icon: Icons.notes_outlined,
          child: SelectableText(data['description']?.toString() ?? ''),
        ),
        const SizedBox(height: 12),
        _DetailSection(
          title: '附件（${attachments.length}）',
          icon: Icons.attach_file,
          child: attachments.isEmpty
              ? const Text('没有附件')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final attachment in attachments)
                      _FeedbackAttachmentView(attachment: attachment),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _DetailSection(
          title: '自动附加日志',
          icon: Icons.article_outlined,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: SelectableText(
              data['clientLogs']?.toString() ?? '未采集到日志',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection(
      {required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: GzusTextStyles.bodyEmphasis(context)),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 72,
              child: Text(label, style: GzusTextStyles.caption(context))),
          Expanded(
              child: SelectableText(value,
                  style: GzusTextStyles.cardSubtitle(context))),
        ],
      ),
    );
  }
}

class _FeedbackAttachmentView extends StatelessWidget {
  const _FeedbackAttachmentView({required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  Widget build(BuildContext context) {
    final name = attachment['name']?.toString() ?? '附件';
    final mimeType = attachment['mimeType']?.toString() ?? '';
    final content = attachment['contentBase64']?.toString() ?? '';
    Uint8List? bytes;
    if (content.isNotEmpty) {
      try {
        bytes = base64Decode(content);
      } on FormatException {
        bytes = null;
      }
    }
    final isImage = mimeType.startsWith('image/') && bytes != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text(_formatBytes(attachment['size']),
                      style: GzusTextStyles.caption(context)),
                ],
              ),
              if (isImage) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const Text('图片无法预览'),
                  ),
                ),
              ] else if (content.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('附件内容不可用'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDate(dynamic value) {
  final text = value?.toString() ?? '';
  return text.length >= 19 ? text.substring(0, 19).replaceAll('T', ' ') : text;
}

String _formatBytes(dynamic value) {
  final bytes = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
