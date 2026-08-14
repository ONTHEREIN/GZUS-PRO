import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';

/// 校历/通知管理页签：上传（标题+说明+图片）、置顶/发布切换、删除。
class NoticesTab extends StatefulWidget {
  const NoticesTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<NoticesTab> createState() => _NoticesTabState();
}

class _NoticesTabState extends State<NoticesTab> {
  late Future<Map<String, dynamic>> _future;
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  Uint8List? _imageBytes;
  String? _imageMime;
  bool _isPinned = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminNotices();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.adminNotices();
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 3 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片不能超过 3MB')),
        );
      }
      return;
    }
    setState(() {
      _imageBytes = bytes;
      _imageMime = switch (file.name.split('.').last.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'bmp' => 'image/bmp',
        _ => 'image/png',
      };
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _uploading = true);
    try {
      final imageData =
          _imageBytes != null ? base64Encode(_imageBytes!) : null;
      await widget.api.adminCreateNotice(
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        imageData: imageData,
        imageMime: imageData != null ? _imageMime : null,
        isPinned: _isPinned,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已发布')),
      );
      _titleCtrl.clear();
      _descCtrl.clear();
      setState(() {
        _imageBytes = null;
        _isPinned = false;
      });
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发布失败: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(int id, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除通知'),
        content: Text('确定删除「$title」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.adminDeleteNotice(id);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  Future<void> _togglePinned(dynamic item) async {
    await widget.api.adminUpdateNotice(
      item['id'] as int,
      isPinned: !(item['isPinned'] as bool? ?? false),
    );
    _refresh();
  }

  Future<void> _togglePublished(dynamic item) async {
    await widget.api.adminUpdateNotice(
      item['id'] as int,
      published: !(item['published'] as bool? ?? true),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainer,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('发布校历/通知',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _titleCtrl,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: '标题（如：2026-2027 学年校历）',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入标题' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _descCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '说明（可选）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickImage,
                            icon: const Icon(Icons.image_outlined),
                            label: Text(_imageBytes != null
                                ? '已选图片 (${(_imageBytes!.length / 1024).round()} KB)'
                                : '选择图片'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_imageBytes != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              _imageBytes!,
                              width: 64,
                              height: 48,
                              fit: BoxFit.cover,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('置顶'),
                      subtitle: const Text('在通知列表优先展示'),
                      value: _isPinned,
                      onChanged: (v) => setState(() => _isPinned = v),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _uploading ? null : _submit,
                        icon: _uploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: Text(_uploading ? '发布中…' : '发布'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('已发布',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          AsyncPanel<Map<String, dynamic>>(
            future: _future,
            emptyMessage: '暂无校历/通知',
            builder: (data) {
              final items = (data['items'] as List<dynamic>?) ?? const [];
              if (items.isEmpty) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: Text('暂无校历/通知')),
                );
              }
              return Column(
                children: [
                  for (final item in items) _NoticeRow(
                    item: item,
                    api: widget.api,
                    onDelete: () => _delete(
                        item['id'] as int, item['title'] as String? ?? ''),
                    onTogglePinned: () => _togglePinned(item),
                    onTogglePublished: () => _togglePublished(item),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.item,
    required this.api,
    required this.onDelete,
    required this.onTogglePinned,
    required this.onTogglePublished,
  });

  final dynamic item;
  final ApiClient api;
  final VoidCallback onDelete;
  final VoidCallback onTogglePinned;
  final VoidCallback onTogglePublished;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pinned = item['isPinned'] as bool? ?? false;
    final published = item['published'] as bool? ?? true;
    final cover = item['coverUrl'] as String?;
    final title = item['title'] as String? ?? '';
    final desc = item['description'] as String?;
    final createdAt = (item['createdAt'] as String?)?.split('T').first ?? '';

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  api.resolveMediaUrl(cover),
                  width: 72,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 72,
                    height: 52,
                    color: colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.image_not_supported_outlined),
                  ),
                ),
              )
            else
              Container(
                width: 72,
                height: 52,
                color: colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.event_note),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  if (desc != null && desc.isNotEmpty)
                    Text(desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      _Tag(text: createdAt, color: GzusColors.muted),
                      if (pinned) const _Tag(text: '置顶', color: GzusColors.amber),
                      if (!published)
                        const _Tag(text: '未发布', color: GzusColors.red),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'pin':
                    onTogglePinned();
                  case 'publish':
                    onTogglePublished();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'pin',
                  child: Text(pinned ? '取消置顶' : '置顶'),
                ),
                PopupMenuItem(
                  value: 'publish',
                  child: Text(published ? '下线' : '发布'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
