import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_client.dart';

const _desktopBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

Future<bool> openAuthenticatedEhallUrl(
  BuildContext context,
  String url, {
  String? fillScript,
  ApiClient? api,
  String? attachmentName,
  Uint8List? attachmentBytes,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (!context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _EhallWebViewPage(
        initialUrl: url,
        fillScript: fillScript,
        api: api,
        attachmentName: attachmentName,
        attachmentBytes: attachmentBytes,
      ),
    ),
  );
  return true;
}

Future<void> clearMobileSsoCookies() {
  return WebViewCookieManager().clearCookies();
}

class _EhallWebViewPage extends StatefulWidget {
  const _EhallWebViewPage({
    required this.initialUrl,
    this.fillScript,
    this.api,
    this.attachmentName,
    this.attachmentBytes,
  });

  final String initialUrl;
  final String? fillScript;
  final ApiClient? api;
  final String? attachmentName;
  final Uint8List? attachmentBytes;

  @override
  State<_EhallWebViewPage> createState() => _EhallWebViewPageState();
}

class _EhallWebViewPageState extends State<_EhallWebViewPage> {
  late final WebViewController controller;
  final cookieManager = WebViewCookieManager();
  bool loading = true;
  bool scriptInjected = false;
  bool scriptApplied = false;
  String? loadError;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopBrowserUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() {
            loading = true;
            loadError = null;
          }),
          onPageFinished: (_) {
            setState(() => loading = false);
            _injectFillScript();
          },
          onWebResourceError: (webError) {
            if (webError.isForMainFrame != true) return;
            if (!mounted) return;
            setState(() {
              loading = false;
              loadError = '办事大厅页面加载失败，请复制脚本后用浏览器打开';
            });
          },
        ),
      );
    _loadInitialUrl();
    _showFallbackIfStillBlank();
  }

  Future<void> _showFallbackIfStillBlank() async {
    if (widget.fillScript == null || widget.fillScript!.isEmpty) return;
    await Future<void>.delayed(const Duration(seconds: 18));
    if (!mounted || scriptApplied || loadError != null) return;
    setState(() {
      loadError = '手机 WebView 无法渲染办事大厅，请复制脚本后在电脑或浏览器执行';
      loading = false;
    });
  }

  Future<void> _injectFillScript() async {
    final script = widget.fillScript;
    if (scriptInjected || script == null || script.isEmpty) return;
    final uri = Uri.tryParse(widget.initialUrl);
    if (uri?.host != 'ehall.gzus.edu.cn') return;
    scriptInjected = true;
    final ready = await _waitForLeaveForm();
    if (!ready) {
      if (!mounted) return;
      setState(() {
        loadError = '表单尚未加载完成，请复制脚本后用浏览器打开';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('表单尚未加载完成，请稍后复制脚本手动执行')),
      );
      return;
    }
    try {
      if (widget.api != null &&
          widget.attachmentName != null &&
          widget.attachmentBytes != null) {
        final uploaded = await _uploadAttachmentFromLoadedForm();
        if (!uploaded) {
          if (!mounted) return;
          setState(() {
            loadError = '附件上传失败，已停止自动办理';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('附件上传失败，未点击办理')),
          );
          return;
        }
      }
      await controller.runJavaScript(script);
      scriptApplied = true;
      if (mounted) setState(() => loadError = null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loadError = '自动填表脚本执行失败，请复制脚本手动执行';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('自动填表脚本执行失败，请复制脚本手动执行')),
      );
    }
  }

  Future<bool> _uploadAttachmentFromLoadedForm() async {
    final fields = await _readLeaveUploadFields();
    if (fields == null || fields.docUnid.isEmpty) return false;
    try {
      return await widget.api!.uploadLeaveAttachment(
        docUnid: fields.docUnid,
        processId: fields.processId,
        nodeName: fields.nodeName,
        localStore: fields.localStore,
        attachmentName: widget.attachmentName!,
        attachmentBytes: widget.attachmentBytes!,
      );
    } catch (_) {
      return false;
    }
  }

  Future<_LeaveUploadFields?> _readLeaveUploadFields() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final raw = await controller.runJavaScriptReturningResult(r"""
(() => JSON.stringify({
  docUnid: document.getElementById('WF_DocUnid')?.value || '',
  processId: document.getElementById('WF_Processid')?.value || '',
  nodeName: document.getElementById('WF_CurrentNodeName')?.value || '申请人',
  localStore: document.getElementById('localStore') ? '1' : '0'
}))()
""");
        final decoded = _decodeWebViewJson(raw);
        if (decoded == null) continue;
        final fields = _LeaveUploadFields.fromJson(decoded);
        if (fields.docUnid.isNotEmpty) return fields;
      } catch (_) {}
    }
    return null;
  }

  Map<String, dynamic>? _decodeWebViewJson(Object raw) {
    try {
      var text = raw.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        text = jsonDecode(text) as String;
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  Future<bool> _waitForLeaveForm() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final result = await controller.runJavaScriptReturningResult("""
(() => Boolean(
  document.getElementById('KSSJ') ||
  document.querySelector('[name="KSSJ"]') ||
  document.getElementById('QJLY') ||
  document.querySelector('[name="QJLY"]')
))()
""");
        if (result == true || result.toString() == 'true') return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _loadInitialUrl() async {
    final uri = Uri.tryParse(widget.initialUrl);
    if (uri == null || uri.host.isEmpty) return;
    await _injectEhallCookies(widget.api?.ehallCookies, uri);
    if (_isGzusHost(uri.host) && widget.fillScript == null) {
      await _primeEhallAuthToken(widget.api?.ehallAuthToken);
    }
    await controller.loadRequest(uri);
  }

  Future<void> _injectEhallCookies(
    String? header,
    Uri targetUri,
  ) async {
    if (!_isGzusHost(targetUri.host)) return;
    if (header == null || header.isEmpty) return;
    final cookies = _parseCookieHeader(header);
    if (cookies.isEmpty) return;
    for (final domain in _cookieDomainsFor(targetUri)) {
      for (final entry in cookies.entries) {
        await cookieManager.setCookie(
          WebViewCookie(
            name: entry.key,
            value: entry.value,
            domain: domain,
            path: '/',
          ),
        );
      }
    }
  }

  List<String> _cookieDomainsFor(Uri targetUri) {
    final host = targetUri.host.toLowerCase();
    final domains = <String>{host};
    if (_isGzusHost(host)) {
      domains
        ..add('ehall.gzus.edu.cn')
        ..add('gzus.edu.cn')
        ..add('.gzus.edu.cn');
    }
    return domains.toList(growable: false);
  }

  bool _isGzusHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'gzus.edu.cn' || normalized.endsWith('.gzus.edu.cn');
  }

  Future<void> _primeEhallAuthToken(String? authToken) async {
    if (authToken == null || authToken.isEmpty) return;
    try {
      await controller.loadRequest(Uri.parse('https://ehall.gzus.edu.cn/'));
      await controller.runJavaScript('''
(() => {
  try {
    const existing = sessionStorage.getItem('userLogin');
    if (!existing) {
      sessionStorage.setItem('userLogin', JSON.stringify({ tokenId: ${jsonEncode(authToken)} }));
    }
  } catch (e) {}
})()
''');
    } catch (_) {}
  }

  Map<String, String> _parseCookieHeader(String header) {
    final cookies = <String, String>{};
    for (final part in header.split(';')) {
      final trimmed = part.trim();
      final separator = trimmed.indexOf('=');
      if (separator <= 0 || separator == trimmed.length - 1) continue;
      cookies[trimmed.substring(0, separator)] =
          trimmed.substring(separator + 1);
    }
    return cookies;
  }

  Future<void> _openInExternalBrowser() async {
    final uri = Uri.tryParse(widget.initialUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyFillScript() async {
    final script = widget.fillScript;
    if (script == null || script.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: script));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('脚本已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(widget.initialUrl)?.host;
    return Scaffold(
      appBar: AppBar(
        title: Text(host == null || host.isEmpty ? '网页' : host),
        actions: [
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (loadError != null)
            MaterialBanner(
              content: Text(loadError!),
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              actions: [
                TextButton(
                  onPressed:
                      widget.fillScript == null || widget.fillScript!.isEmpty
                          ? null
                          : _copyFillScript,
                  child: const Text('复制脚本'),
                ),
                TextButton(
                  onPressed: _openInExternalBrowser,
                  child: const Text('浏览器打开'),
                ),
              ],
            ),
          Expanded(child: WebViewWidget(controller: controller)),
        ],
      ),
    );
  }
}

class _LeaveUploadFields {
  const _LeaveUploadFields({
    required this.docUnid,
    required this.processId,
    required this.nodeName,
    required this.localStore,
  });

  factory _LeaveUploadFields.fromJson(Map<String, dynamic> json) =>
      _LeaveUploadFields(
        docUnid: json['docUnid'] as String? ?? '',
        processId: json['processId'] as String? ?? '',
        nodeName: json['nodeName'] as String? ?? '申请人',
        localStore: json['localStore'] as String? ?? '0',
      );

  final String docUnid;
  final String processId;
  final String nodeName;
  final String localStore;
}
