import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';

/// 公众号文章管理页签：同步状态/立即同步/粘贴导入/文章列表（隐藏、删除）。
class WechatTab extends StatefulWidget {
  const WechatTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<WechatTab> createState() => _WechatTabState();
}

class _WechatTabState extends State<WechatTab> {
  late Future<Map<String, dynamic>> _statusFuture;
  late Future<Map<String, dynamic>> _articlesFuture;
  final _importCtrl = TextEditingController();
  bool _syncing = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.api.adminWechatStatus();
    _articlesFuture = widget.api.adminWechatArticles();
  }

  @override
  void dispose() {
    _importCtrl.dispose();
    super.dispose();
  }

  void _refreshAll() {
    setState(() {
      _statusFuture = widget.api.adminWechatStatus();
      _articlesFuture = widget.api.adminWechatArticles();
    });
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      final result = await widget.api.adminWechatSync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result['error'] != null
              ? '同步失败: ${result['error']}'
              : '同步完成，新增 ${result['added'] ?? 0} 篇',
        ),
      ));
      _refreshAll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('同步失败: $e')));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _importByUrl() async {
    final url = _importCtrl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请粘贴公众号文章链接')));
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await widget.api.adminWechatImport(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result['added'] == 1
            ? '已导入「${result['title']}」'
            : '该文章已在列表中'),
      ));
      _importCtrl.clear();
      _refreshAll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败: $e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _toggleHidden(dynamic item) async {
    final id = item['id'] as int;
    final hidden = item['hidden'] as bool? ?? false;
    await widget.api.adminWechatSetHidden(id, !hidden);
    _refreshAll();
  }

  Future<void> _delete(dynamic item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文章'),
        content: Text('确定删除「${item['title']}」吗？'),
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
    await widget.api.adminWechatDelete(item['id'] as int);
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refreshAll();
        await _articlesFuture;
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AsyncPanel<Map<String, dynamic>>(
            future: _statusFuture,
            emptyMessage: '暂无同步状态',
            builder: (status) {
              final configured = status['configured'] as bool? ?? false;
              final lastSynced = status['lastSyncedAt'] as String?;
              return Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('公众号同步',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            configured
                                ? Icons.check_circle
                                : Icons.error_outline,
                            size: 18,
                            color: configured
                                ? GzusColors.green
                                : GzusColors.amber,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              configured
                                  ? '已配置合集，自动同步已开启（每 ${status['syncIntervalHours'] ?? 6} 小时）'
                                  : '未配置合集链接（环境变量 WECHAT_ALBUM_URL），自动同步未开启',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        lastSynced != null
                            ? '上次同步：$lastSynced'
                            : '尚未同步过',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _syncing ? null : _syncNow,
                          icon: _syncing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.sync),
                          label: Text(_syncing ? '同步中…' : '立即同步'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _importCtrl,
                        decoration: const InputDecoration(
                          labelText: '粘贴公众号文章链接',
                          hintText: 'https://mp.weixin.qq.com/s/...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _importing ? null : _importByUrl,
                          icon: const Icon(Icons.link),
                          label: Text(_importing ? '导入中…' : '导入'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('文章列表', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          AsyncPanel<Map<String, dynamic>>(
            future: _articlesFuture,
            emptyMessage: '暂无公众号文章',
            builder: (data) {
              final items = (data['items'] as List<dynamic>?) ?? const [];
              if (items.isEmpty) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: Text('暂无公众号文章')),
                );
              }
              return Column(
                children: [
                  for (final item in items)
                    _ArticleRow(
                      item: item,
                      api: widget.api,
                      onToggleHidden: () => _toggleHidden(item),
                      onDelete: () => _delete(item),
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

class _ArticleRow extends StatelessWidget {
  const _ArticleRow({
    required this.item,
    required this.api,
    required this.onToggleHidden,
    required this.onDelete,
  });

  final dynamic item;
  final ApiClient api;
  final VoidCallback onToggleHidden;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hidden = item['hidden'] as bool? ?? false;
    final title = item['title'] as String? ?? '';
    final publishTime = item['publishTime'] as String?;
    final cover = item['coverUrl'] as String?;

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
                  cover,
                  width: 72,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 72,
                    height: 52,
                    color: colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.campaign_outlined),
                  ),
                ),
              )
            else
              Container(
                width: 72,
                height: 52,
                color: colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.campaign_outlined),
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
                  Wrap(
                    spacing: 6,
                    children: [
                      if (publishTime != null)
                        Text(publishTime,
                            style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant)),
                      if (hidden)
                        const _Tag2(text: '已隐藏', color: GzusColors.red),
                      _Tag2(
                          text: item['source'] == 'paste' ? '手动导入' : '合集同步',
                          color: GzusColors.muted),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'hide':
                    onToggleHidden();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'hide',
                  child: Text(hidden ? '取消隐藏' : '隐藏'),
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

class _Tag2 extends StatelessWidget {
  const _Tag2({required this.text, required this.color});

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
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
