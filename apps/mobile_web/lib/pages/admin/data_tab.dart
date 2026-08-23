import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';

/// 数据统计页签：Web Push 订阅 / 数据库缓存（可清空）/ 水电费绑定。
class DataTab extends StatefulWidget {
  const DataTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<DataTab> createState() => _DataTabState();
}

class _DataTabState extends State<DataTab> {
  late Future<Map<String, dynamic>> _pushFuture;
  late Future<Map<String, dynamic>> _cacheFuture;
  late Future<Map<String, dynamic>> _ecardFuture;

  @override
  void initState() {
    super.initState();
    _pushFuture = widget.api.adminPush();
    _cacheFuture = widget.api.adminCache();
    _ecardFuture = widget.api.adminEcard();
  }

  void _refresh() {
    setState(() {
      _pushFuture = widget.api.adminPush();
      _cacheFuture = widget.api.adminCache();
      _ecardFuture = widget.api.adminEcard();
    });
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空数据库缓存？'),
        content: const Text('将删除 data_cache 表中的全部缓存条目，'
            '下次查询会回源学校系统，可能变慢。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await widget.api.adminClearCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清空 ${result['deleted'] ?? 0} 条缓存')),
      );
      _refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  String _fmt(dynamic value) {
    if (value == null) return '-';
    final s = value.toString();
    return s.length >= 19 ? s.substring(0, 19).replaceAll('T', ' ') : s;
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await Future.wait([_pushFuture, _cacheFuture, _ecardFuture]);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'Web Push 订阅',
            icon: Icons.notifications,
            trailing: AsyncPanel<Map<String, dynamic>>(
              future: _pushFuture,
              builder: (data) => Text(
                '共 ${data['webCount'] ?? 0} 个订阅',
                style: GzusTextStyles.cardSubtitle(context),
              ),
            ),
            child: AsyncPanel<Map<String, dynamic>>(
              future: _pushFuture,
              builder: (data) {
                final web = (data['web'] as List<dynamic>? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .take(5)
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final row in web)
                      _RowLine(
                        leading: const Icon(Icons.language, size: 16),
                        text: '${row['studentId']} · ${_fmt(row['createdAt'])}',
                      ),
                    if (web.isEmpty)
                      Text('暂无 Web Push 订阅',
                          style: GzusTextStyles.caption(context)),
                  ],
                );
              },
            ),
          ),
          _SectionCard(
            title: '数据库缓存',
            icon: Icons.storage,
            trailing: TextButton.icon(
              onPressed: _clearCache,
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('清空'),
            ),
            child: AsyncPanel<Map<String, dynamic>>(
              future: _cacheFuture,
              builder: (data) {
                final items = (data['items'] as List<dynamic>? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .take(5)
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final row in items)
                      _RowLine(
                        leading: StatusPill(
                          label: '${row['resource'] ?? '-'}',
                          color: GzusColors.blue,
                        ),
                        text: '${row['studentId']} · ${_fmt(row['cachedAt'])}',
                        secondary: row['cacheKey']?.toString(),
                      ),
                    if (items.isEmpty)
                      Text('暂无缓存',
                          style: GzusTextStyles.caption(context)),
                  ],
                );
              },
            ),
          ),
          _SectionCard(
            title: '水电费绑定',
            icon: Icons.electric_bolt,
            trailing: AsyncPanel<Map<String, dynamic>>(
              future: _ecardFuture,
              builder: (data) => Text(
                '共 ${data['total'] ?? 0} · 提醒 ${data['reminderEnabled'] ?? 0}',
                style: GzusTextStyles.cardSubtitle(context),
              ),
            ),
            child: AsyncPanel<Map<String, dynamic>>(
              future: _ecardFuture,
              builder: (data) {
                final items = (data['items'] as List<dynamic>? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .take(5)
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final row in items)
                      _RowLine(
                        leading: Icon(
                          row['reminderEnabled'] == true
                              ? Icons.notifications_active
                              : Icons.notifications_off,
                          size: 16,
                          color: row['reminderEnabled'] == true
                              ? GzusColors.green
                              : GzusColors.muted,
                        ),
                        text:
                            '${row['studentId']} · ${row['roomDisplay'] ?? '-'}',
                        secondary: '更新于 ${_fmt(row['updatedAt'])}',
                      ),
                    if (items.isEmpty)
                      Text('暂无绑定',
                          style: GzusTextStyles.caption(context)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组卡片：标题行 + 内容。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: GzusTextStyles.bodyEmphasis(context)),
                ),
                if (trailing != null) trailing!,
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

/// 单行信息（leading 图标/标签 + 主文本 + 可选次文本）。
class _RowLine extends StatelessWidget {
  const _RowLine({
    required this.leading,
    required this.text,
    this.secondary,
  });

  final Widget leading;
  final String text;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GzusTextStyles.cardSubtitle(context)),
                if (secondary != null)
                  Text(secondary!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GzusTextStyles.caption(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
