import 'dart:async';

import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../shiply_export_download.dart';

class ShiplyTab extends StatefulWidget {
  const ShiplyTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<ShiplyTab> createState() => _ShiplyTabState();
}

class _ShiplyTabState extends State<ShiplyTab> {
  final Map<ShiplyExportResource, ShiplyExportJob> _jobs = {};
  final Map<ShiplyExportResource, String> _errors = {};
  Timer? _pollTimer;
  bool _loading = true;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLatestJobs());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLatestJobs() async {
    try {
      final jobs = await widget.api.adminShiplyExports();
      if (!mounted) return;
      setState(() {
        for (final resource in ShiplyExportResource.values) {
          ShiplyExportJob? latest;
          for (final job in jobs) {
            if (job.resource == resource) {
              latest = job;
              break;
            }
          }
          if (latest != null) _jobs[resource] = latest;
        }
        _loading = false;
      });
      _ensurePolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        for (final resource in ShiplyExportResource.values) {
          _errors[resource] = '$error';
        }
      });
    }
  }

  Future<void> _create(ShiplyExportResource resource) async {
    setState(() => _errors.remove(resource));
    try {
      final job = await widget.api.adminCreateShiplyExport(resource);
      if (!mounted) return;
      setState(() => _jobs[resource] = job);
      _ensurePolling();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[resource] = '$error');
    }
  }

  Future<void> _poll() async {
    if (_polling) return;
    final activeJobs =
        _jobs.values.where((job) => job.isActive).toList(growable: false);
    if (activeJobs.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _polling = true;
    try {
      final updated = await Future.wait(
        activeJobs.map((job) => widget.api.adminShiplyExport(job.id)),
      );
      if (!mounted) return;
      setState(() {
        for (final job in updated) {
          _jobs[job.resource] = job;
          if (job.error != null) _errors[job.resource] = job.error!;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        for (final job in activeJobs) {
          _errors[job.resource] = '$error';
        }
      });
    } finally {
      _polling = false;
      _ensurePolling();
    }
  }

  void _ensurePolling() {
    if (!mounted) return;
    final hasActive = _jobs.values.any((job) => job.isActive);
    if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll());
    });
    unawaited(_poll());
  }

  Future<void> _download(ShiplyExportJob job) async {
    try {
      final result = await widget.api.adminDownloadShiplyExport(job);
      await downloadShiplyExport(result.bytes, result.filename);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[job.resource] = '$error');
    }
  }

  String _resourceTitle(ShiplyExportResource resource) {
    return switch (resource) {
      ShiplyExportResource.login => '登录页资源',
      ShiplyExportResource.home => '首页资源',
    };
  }

  String _resourceDescription(ShiplyExportResource resource) {
    return switch (resource) {
      ShiplyExportResource.login => '仅包含已发布登录轮播图，未登录屏幕单独读取。',
      ShiplyExportResource.home => '包含已发布管理员通知/校历与未隐藏公众号文章，供首页和通知页读取。',
    };
  }

  String _statusLabel(ShiplyExportJob job) {
    return switch (job.status) {
      'queued' => '等待生成',
      'running' => '生成中',
      'succeeded' => '已生成',
      'failed' => '生成失败',
      _ => job.status,
    };
  }

  Widget _resourceCard(BuildContext context, ShiplyExportResource resource) {
    final job = _jobs[resource];
    final error = _errors[resource];
    final active = job?.isActive ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_resourceTitle(resource),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(_resourceDescription(resource)),
            const SizedBox(height: 6),
            SelectableText('资源 Key：${resource.resourceKey}'),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: active ? null : () => _create(resource),
                  icon: active
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.archive_outlined),
                  label: Text(active ? _statusLabel(job!) : '生成资源包'),
                ),
                if (job?.isSucceeded ?? false)
                  OutlinedButton.icon(
                    onPressed: () => _download(job!),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('下载 ZIP'),
                  ),
              ],
            ),
            if (job != null) ...[
              const Divider(height: 28),
              Text('状态：${_statusLabel(job)}'),
              Text('创建时间：${job.createdAt}'),
              if (job.generatedAt != null) Text('生成时间：${job.generatedAt}'),
              if (job.sha256 != null) SelectableText('摘要：${job.sha256}'),
              if (job.counts != null)
                Text(
                  '内容数量：${job.counts!.entries.map((item) => '${item.key}=${item.value}').join('，')}',
                ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Shiply 远程资源', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          '分别生成并下载两个 ZIP；将同一资源包上传到 Android 与 iOS 对应 Shiply 产品后完成发布。',
        ),
        const SizedBox(height: 12),
        if (_loading) const LinearProgressIndicator(),
        _resourceCard(context, ShiplyExportResource.login),
        _resourceCard(context, ShiplyExportResource.home),
      ],
    );
  }
}
