import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';

Future<bool> openAuthenticatedEhallUrl(
  BuildContext context,
  String url, {
  String? fillScript,
  ApiClient? api,
  String? attachmentName,
  Uint8List? attachmentBytes,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return Future.value(false);
  return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

Future<void> clearMobileSsoCookies() async {}
