import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';

/// 会话页签：会话列表 + 强制踢下线。
class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminSessions();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.adminSessions();
    });
  }

  Future<void> _confirmRevoke(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认下线会话？'),
        content: Text(
          '学号 ${row['studentAccount'] ?? '-'} 的会话将被强制下线，'
          '该用户下次请求会收到 401 并重新登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('下线'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.api.adminRevokeSession(row['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('会话已下线')),
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
        await _future;
      },
      child: AsyncPanel<Map<String, dynamic>>(
        future: _future,
        emptyMessage: '暂无会话',
        builder: (data) {
          final items = (data['items'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '共 ${data['total'] ?? 0} 个会话（最近 ${items.length} 个）',
                    style: GzusTextStyles.caption(context),
                  ),
                );
              }
              final row = items[index - 1];
              final revoked = row['revokedAt'] != null;
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${row['studentAccount'] ?? '-'}',
                          overflow: TextOverflow.ellipsis,
                          style: GzusTextStyles.bodyEmphasis(context),
                        ),
                      ),
                      if (row['studentName'] != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${row['studentName']}',
                            overflow: TextOverflow.ellipsis,
                            style: GzusTextStyles.caption(context),
                          ),
                        ),
                      ],
                      if (row['isAdmin'] == true) ...[
                        const SizedBox(width: 8),
                        const StatusPill(label: '管理员', color: GzusColors.amber),
                      ],
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '创建 ${_fmt(row['createdAt'])} · 活跃 ${_fmt(row['lastActiveAt'])}',
                      style: GzusTextStyles.caption(context),
                    ),
                  ),
                  trailing: revoked
                      ? const StatusPill(label: '已下线', color: GzusColors.red)
                      : TextButton(
                          onPressed: () => _confirmRevoke(row),
                          child: const Text('下线'),
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
