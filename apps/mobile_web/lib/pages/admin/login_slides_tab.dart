import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api_client.dart';
import '../../widgets/async_panel.dart';

class LoginSlidesTab extends StatefulWidget {
  const LoginSlidesTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<LoginSlidesTab> createState() => _LoginSlidesTabState();
}

class _LoginSlidesTabState extends State<LoginSlidesTab> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  late Future<Map<String, dynamic>> _future;
  Uint8List? _imageBytes;
  String? _imageMime;
  String? _currentImageUrl;
  int? _editingSlideId;
  bool _published = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminLoginSlides();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() => _future = widget.api.adminLoginSlides());
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.length > 3 * 1024 * 1024) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片不能超过 3MB')));
      return;
    }
    setState(() {
      _imageBytes = bytes;
      _imageMime = _mimeTypeOf(file.name);
    });
  }

  String _mimeTypeOf(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      _ => 'image/png',
    };
  }

  void _resetEditor() {
    _formKey.currentState?.reset();
    _titleController.clear();
    _descriptionController.clear();
    setState(() {
      _imageBytes = null;
      _imageMime = null;
      _currentImageUrl = null;
      _editingSlideId = null;
      _published = true;
    });
  }

  void _startEditing(Map<String, dynamic> item) {
    setState(() {
      _editingSlideId = item['id'] as int;
      _titleController.text = item['title'] as String? ?? '';
      _descriptionController.text = item['description'] as String? ?? '';
      _currentImageUrl = item['imageUrl'] as String?;
      _imageBytes = null;
      _imageMime = null;
      _published = item['published'] as bool? ?? true;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final editingSlideId = _editingSlideId;
    if (editingSlideId == null && _imageBytes == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请为轮播图选择图片')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final title = _titleController.text.trim();
      final description = _descriptionController.text.trim();
      final imageData = _imageBytes == null ? null : base64Encode(_imageBytes!);
      if (editingSlideId == null) {
        await widget.api.adminCreateLoginSlide(
          title: title,
          description: description.isEmpty ? null : description,
          imageData: imageData!,
          imageMime: _imageMime!,
          published: _published,
        );
      } else {
        await widget.api.adminUpdateLoginSlide(
          editingSlideId,
          title: title,
          description: description.isEmpty ? null : description,
          imageData: imageData,
          imageMime: _imageMime,
          published: _published,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(editingSlideId == null ? '轮播图已创建' : '轮播图已更新')),
      );
      _resetEditor();
      _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $error')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final title = item['title'] as String? ?? '该轮播图';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除轮播图'),
        content: Text('确定删除「$title」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.adminDeleteLoginSlide(item['id'] as int);
      if (_editingSlideId == item['id']) _resetEditor();
      _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败: $error')));
    }
  }

  Future<void> _move(
      List<Map<String, dynamic>> items, int index, int offset) async {
    final nextIndex = index + offset;
    if (nextIndex < 0 || nextIndex >= items.length) return;
    final reordered = [...items];
    final item = reordered.removeAt(index);
    reordered.insert(nextIndex, item);
    try {
      await widget.api.adminReorderLoginSlides(
          reordered.map((item) => item['id'] as int).toList());
      _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('排序失败: $error')));
    }
  }

  List<Map<String, dynamic>> _itemsOf(Map<String, dynamic> data) {
    final rawItems = data['items'];
    if (rawItems is! List<dynamic>) return const [];
    return rawItems.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editingSlideId != null;
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      editing ? '编辑登录轮播图' : '新建登录轮播图',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '建议使用 16:10 横图；已发布内容最多 5 张。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _titleController,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: '标题',
                        counterText: '',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? '请输入标题'
                              : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _descriptionController,
                      maxLength: 500,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '文案（可选）',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _submitting ? null : _pickImage,
                            icon: const Icon(Icons.image_outlined),
                            label:
                                Text(_imageBytes == null ? '选择图片' : '已选择新图片'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _SlideImagePreview(
                          bytes: _imageBytes,
                          imageUrl: _currentImageUrl,
                          api: widget.api,
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('发布'),
                      subtitle: const Text('发布后会在登录页轮播中展示'),
                      value: _published,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() => _published = value),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Icon(editing
                                    ? Icons.save_outlined
                                    : Icons.add_photo_alternate_outlined),
                            label: Text(_submitting
                                ? '保存中…'
                                : editing
                                    ? '保存修改'
                                    : '创建轮播图'),
                          ),
                        ),
                        if (editing) ...[
                          const SizedBox(width: 12),
                          TextButton(
                              onPressed: _resetEditor,
                              child: const Text('取消编辑')),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('轮播顺序', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          AsyncPanel<Map<String, dynamic>>(
            future: _future,
            emptyMessage: '暂无登录轮播图',
            builder: (data) {
              final items = _itemsOf(data);
              if (items.isEmpty) {
                return const SizedBox(
                    height: 80, child: Center(child: Text('暂无登录轮播图')));
              }
              return Column(
                children: [
                  for (var index = 0; index < items.length; index++)
                    _SlideRow(
                      item: items[index],
                      index: index,
                      itemCount: items.length,
                      api: widget.api,
                      onEdit: _startEditing,
                      onDelete: _delete,
                      onMove: (offset) => _move(items, index, offset),
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

class _SlideImagePreview extends StatelessWidget {
  const _SlideImagePreview(
      {required this.bytes, required this.imageUrl, required this.api});

  final Uint8List? bytes;
  final String? imageUrl;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final selectedBytes = bytes;
    if (selectedBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(selectedBytes,
            width: 72, height: 54, fit: BoxFit.cover),
      );
    }
    final url = imageUrl;
    if (url != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          api.resolveMediaUrl(url),
          headers: api.sessionId == null
              ? null
              : <String, String>{'X-Session-Id': api.sessionId!},
          width: 72,
          height: 54,
          fit: BoxFit.cover,
        ),
      );
    }
    return const SizedBox(width: 72, height: 54);
  }
}

class _SlideRow extends StatelessWidget {
  const _SlideRow({
    required this.item,
    required this.index,
    required this.itemCount,
    required this.api,
    required this.onEdit,
    required this.onDelete,
    required this.onMove,
  });

  final Map<String, dynamic> item;
  final int index;
  final int itemCount;
  final ApiClient api;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onDelete;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final title = item['title'] as String? ?? '';
    final description = item['description'] as String?;
    final imageUrl = item['imageUrl'] as String?;
    final published = item['published'] as bool? ?? false;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: imageUrl == null
            ? const Icon(Icons.image_not_supported_outlined)
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  api.resolveMediaUrl(imageUrl),
                  headers: api.sessionId == null
                      ? null
                      : <String, String>{'X-Session-Id': api.sessionId!},
                  width: 52,
                  height: 42,
                  fit: BoxFit.cover,
                ),
              ),
        title: Text(title),
        subtitle: Text(
            '${published ? '已发布' : '未发布'}${description == null || description.isEmpty ? '' : ' · $description'}'),
        trailing: Wrap(
          spacing: 0,
          children: [
            IconButton(
              onPressed: index == 0 ? null : () => onMove(-1),
              icon: const Icon(Icons.keyboard_arrow_up),
              tooltip: '上移',
            ),
            IconButton(
              onPressed: index == itemCount - 1 ? null : () => onMove(1),
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: '下移',
            ),
            IconButton(
              onPressed: () => onEdit(item),
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
            ),
            IconButton(
              onPressed: () => onDelete(item),
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
            ),
          ],
        ),
      ),
    );
  }
}
