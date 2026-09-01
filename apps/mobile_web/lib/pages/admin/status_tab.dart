import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';

/// 系统页签：系统状态（脱敏）+ 敏感操作审计日志。
class StatusTab extends StatefulWidget {
  const StatusTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<StatusTab> {
  late Future<Map<String, dynamic>> _statusFuture;
  late Future<Map<String, dynamic>> _auditFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.api.adminStatus();
    _auditFuture = widget.api.adminAuditLog();
  }

  void _refresh() {
    setState(() {
      _statusFuture = widget.api.adminStatus();
      _auditFuture = widget.api.adminAuditLog();
    });
  }

  String _fmt(dynamic value) {
    if (value == null) return '-';
    final s = value.toString();
    return s.length >= 19 ? s.substring(0, 19).replaceAll('T', ' ') : s;
  }

  String _actionLabel(String action) {
    return switch (action) {
      'revoke_session' => '踢下线',
      'add_admin' => '添加管理员',
      'remove_admin' => '删除管理员',
      'clear_cache' => '清空缓存',
      _ => action,
    };
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await Future.wait([_statusFuture, _auditFuture]);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AsyncPanel<Map<String, dynamic>>(
            future: _statusFuture,
            emptyMessage: '暂无系统状态',
            builder: (data) {
              final isProd = data['debug'] != true;
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12),
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.monitor_heart, size: 18),
                          const SizedBox(width: 8),
                          Text('系统状态',
                              style: GzusTextStyles.bodyEmphasis(context)),
                          const Spacer(),
                          StatusPill(
                            label: isProd ? '生产环境' : '开发环境',
                            color: isProd ? GzusColors.green : GzusColors.amber,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const _KeyValueRow(label: '服务状态', value: '正常'),
                      _KeyValueRow(
                          label: '部署形态',
                          value: data['runtime'] == 'self_hosted'
                              ? '腾讯云自托管'
                              : '未知'),
                      _KeyValueRow(
                          label: '服务器时间 (UTC)',
                          value: _fmt(data['timeUtc'])),
                      _KeyValueRow(
                          label: '会话有效期',
                          value: '${data['sessionTtlSeconds'] ?? '-'} 秒'),
                      _KeyValueRow(
                          label: 'App 版本',
                          value:
                              '${data['appVersion'] ?? '-'} (${data['appBuild'] ?? '-'})'),
                      _KeyValueRow(
                        label: '后台持续通知授权',
                        value: '${data['backgroundNotificationProfiles'] ?? 0} 人',
                      ),
                      _KeyValueRow(
                        label: 'Web Push',
                        value: data['webPushEnabled'] == true ? '已启用' : '未配置或配置错误',
                      ),
                      _KeyValueRow(
                        label: 'APNs',
                        value: data['apnsError'] ??
                            (data['apnsEnabled'] == true ? '已启用' : '未配置'),
                      ),
                      for (final job in (data['maintenanceJobs'] as List<dynamic>? ?? const [])
                          .whereType<Map<String, dynamic>>())
                        _KeyValueRow(
                          label: '${job['name'] ?? '维护任务'}',
                          value: job['lastError'] == null
                              ? '成功 · ${_fmt(job['lastSucceededAt'])} · ${job['lastDurationMs'] ?? '-'}ms · 处理 ${job['lastProcessed'] ?? 0} · 投递 ${job['lastDelivered'] ?? 0}'
                              : '失败 · ${job['lastError']}',
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          AsyncPanel<Map<String, dynamic>>(
            future: _auditFuture,
            emptyMessage: '暂无审计日志',
            builder: (data) {
              final items = (data['items'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12),
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.receipt_long, size: 18),
                          const SizedBox(width: 8),
                          Text('审计日志（最近 ${items.length} 条）',
                              style: GzusTextStyles.bodyEmphasis(context)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final row in items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              StatusPill(
                                label: _actionLabel(
                                    '${row['action'] ?? '-'}'),
                                color: GzusColors.blue,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${row['operatorId'] ?? '-'}'
                                      '${row['targetId'] != null ? ' → ${row['targetId']}' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          GzusTextStyles.cardSubtitle(context),
                                    ),
                                    Text(
                                      _fmt(row['createdAt']),
                                      style: GzusTextStyles.caption(context),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 键值行（系统状态用）。
class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: GzusTextStyles.caption(context)),
          ),
          Expanded(
            child: Text(value,
                style: GzusTextStyles.cardSubtitle(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
