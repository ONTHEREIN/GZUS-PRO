import 'package:flutter/material.dart';

import '../api_client.dart';
import '../mobile_sso.dart' deferred as mobile_sso;

/// 打开 ehall 认证链接（内部先加载 mobile_sso 延迟库）。
Future<void> openInAppBrowser(
  BuildContext context,
  String? url, {
  required ApiClient api,
}) async {
  if (url == null || url.isEmpty) return;
  await mobile_sso.loadLibrary();
  if (!context.mounted) return;
  final opened = await mobile_sso.openAuthenticatedEhallUrl(
    context,
    url,
    attachments: const [],
    api: api,
    handlerScript: null,
    leaveSummary: null,
    onSessionExpired: null,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接')),
    );
  }
}
