import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';

/// 管理员页签：白名单列表 + 添加/删除（仅 owner 可操作）。
class UsersTab extends StatefulWidget {
  const UsersTab({super.key, required this.api, this.isOwner = false});

  final ApiClient api;
  final bool isOwner;

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminUsers();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.adminUsers();
    });
  }

  Future<void> _showAddDialog() async {
    final controller = TextEditingController();
    String role = 'admin';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加管理员'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '学号',
                  hintText: '请输入要添加的学号',
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'admin', label: Text('管理员')),
                  ButtonSegment(value: 'owner', label: Text('Owner')),
                ],
                selected: {role},
                onSelectionChanged: (selection) =>
                    setDialogState(() => role = selection.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true) return;
    final studentId = controller.text.trim();
    if (studentId.isEmpty) return;

    try {
      await widget.api.adminAddUser(studentId, role);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加管理员 $studentId')),
      );
      _refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _confirmRemove(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除管理员？'),
        content: Text('学号 ${row['studentId']} 将失去管理后台访问权限。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.api.adminRemoveUser(row['studentId'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除管理员')),
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
    return Column(
      children: [
        if (widget.isOwner)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _showAddDialog,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('添加管理员'),
              ),
            ),
          ),
        Expanded(
          child: PageRefresh(
            onRefresh: () async {
              _refresh();
              await _future;
            },
            child: AsyncPanel<Map<String, dynamic>>(
              future: _future,
              emptyMessage: '暂无管理员（可在 .env 配置 ADMIN_SEED_OWNER 初始化）',
              builder: (data) {
                final items = (data['items'] as List<dynamic>? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .toList();
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final row = items[index];
                    final isOwner = row['role'] == 'owner';
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
                                '${row['studentId']}',
                                overflow: TextOverflow.ellipsis,
                                style: GzusTextStyles.bodyEmphasis(context),
                              ),
                            ),
                            const SizedBox(width: 8),
                            StatusPill(
                              label: isOwner ? 'Owner' : '管理员',
                              color:
                                  isOwner ? GzusColors.amber : GzusColors.blue,
                            ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '添加于 ${_fmt(row['createdAt'])}',
                            style: GzusTextStyles.caption(context),
                          ),
                        ),
                        trailing: widget.isOwner
                            ? TextButton(
                                onPressed: () => _confirmRemove(row),
                                child: const Text('移除'),
                              )
                            : null,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
