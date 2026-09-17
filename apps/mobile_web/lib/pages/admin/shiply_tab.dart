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
  bool _exporting = false;
  ShiplyContentExport? _lastExport;
  String? _error;

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final result = await widget.api.adminExportShiplyPublicContent();
      await downloadShiplyExport(result.bytes);
      if (!mounted) return;
      setState(() => _lastExport = result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('资源包已生成，请分别上传到 Android/iOS Shiply 产品并发布')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _lastExport;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shiply 公共资源',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  '生成已发布校历/通知、登录轮播和未隐藏公众号文章的 ZIP。生成后请使用同一文件分别上传 Android 与 iOS 产品，再完成正式发布。',
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _exporting ? null : _export,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.archive_outlined),
                  label: Text(_exporting ? '生成中...' : '生成 Shiply 资源包'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                if (result != null) ...[
                  const Divider(height: 28),
                  Text('最近一次生成：${result.generatedAt}'),
                  const SizedBox(height: 4),
                  Text('摘要：${result.sha256}'),
                  const SizedBox(height: 4),
                  Text(
                      '内容数量：${result.counts.entries.map((entry) => '${entry.key}=${entry.value}').join('，')}'),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
