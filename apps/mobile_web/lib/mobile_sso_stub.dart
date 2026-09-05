import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'leave_attachment_models.dart';

Future<bool> openAuthenticatedEhallUrl(
  BuildContext context,
  String url, {
  String? fillScript,
  String? handlerScript,
  required List<PickedAttachment> attachments,
  required ApiClient api,
  required String? leaveSummary,
  required VoidCallback? onSessionExpired,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return Future.value(false);
  // Web 无法注入学校 Cookie，直接交给外部浏览器/新标签页打开。
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> clearMobileSsoCookies() async {}
