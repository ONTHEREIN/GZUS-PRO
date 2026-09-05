import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_client.dart';
import 'leave_attachment_models.dart';
import 'leave_attachment_upload.dart';
import 'mobile_sso_cookies.dart';

const _desktopBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

Future<bool> openAuthenticatedEhallUrl(
  BuildContext context,
  String url, {
  String? fillScript,
  required List<PickedAttachment> attachments,
  required ApiClient api,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (!context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _EhallWebViewPage(
        initialUrl: url,
        fillScript: fillScript,
        attachments: attachments,
        api: api,
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
    required this.api,
    required this.attachments,
    this.fillScript,
  });

  final String initialUrl;
  final String? fillScript;
  final List<PickedAttachment> attachments;
  final ApiClient api;

  @override
  State<_EhallWebViewPage> createState() => _EhallWebViewPageState();
}

class _EhallWebViewPageState extends State<_EhallWebViewPage> {
  late final WebViewController controller;
  final cookieManager = WebViewCookieManager();
  bool loading = true;
  bool scriptInjected = false;
  bool attachmentsUploaded = false;
  bool attachmentsUploading = false;
  String? loadError;
  LeaveFormAttachmentMetadata? leaveFormMetadata;
  String? _pendingUserLoginToken;
  Uri? _pendingTargetUrl;

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
          onPageFinished: (url) {
            setState(() => loading = false);
            unawaited(_handlePageFinished(url));
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
    if (!mounted ||
        attachmentsUploaded ||
        attachmentsUploading ||
        loadError != null) {
      return;
    }
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
      await _installLeaveSubmissionGate();
      await controller.runJavaScript(script);
      await _uploadLeaveAttachments();
      if (mounted) setState(() => loadError = null);
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        loadError = _leaveAutomationErrorMessage(exc);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loadError!)),
      );
    }
  }

  Future<void> _installLeaveSubmissionGate() {
    return controller.runJavaScript('''
(() => {
  if (window.__gzusLeaveSubmissionGate) return;
  window.__gzusLeaveSubmissionLocked = true;
  const block = (event) => {
    if (window.__gzusLeaveSubmissionLocked) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  };
  document.addEventListener('submit', block, true);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') block(event);
  }, true);
  const overlay = document.createElement('div');
  overlay.id = 'gzus-leave-submission-gate';
  overlay.setAttribute('role', 'alert');
  overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:flex;align-items:center;justify-content:center;background:rgba(255,255,255,.78);color:#1f2937;font:16px sans-serif;text-align:center;padding:24px;';
  overlay.innerHTML = '<div style="max-width:280px;padding:18px;border-radius:12px;background:#fff;box-shadow:0 8px 28px rgba(0,0,0,.2)">正在填写请假单并上传附件，请勿提交…</div>';
  document.body.appendChild(overlay);
  window.__gzusLeaveSubmissionGate = {
    unlock: () => {
      window.__gzusLeaveSubmissionLocked = false;
      overlay.remove();
    }
  };
})();
''');
  }

  Future<void> _uploadLeaveAttachments() async {
    final attachments = widget.attachments;
    if (attachments.isEmpty) {
      await _unlockLeaveSubmissionGate();
      attachmentsUploaded = true;
      return;
    }
    if (mounted) setState(() => attachmentsUploading = true);
    try {
      final metadata = leaveFormMetadata ?? await _waitForLeaveFormMetadata();
      leaveFormMetadata = metadata;
      await uploadLeaveAttachments(
        attachments,
        metadata,
        (formMetadata, attachment) => widget.api.uploadLeaveAttachment(
          docUnid: formMetadata.docUnid,
          processId: formMetadata.processId,
          nodeName: formMetadata.nodeName,
          localStore: formMetadata.localStore,
          attachmentName: attachment.name,
          attachmentBytes: attachment.bytes,
        ),
      );
      await _unlockLeaveSubmissionGate();
      attachmentsUploaded = true;
    } finally {
      if (mounted) setState(() => attachmentsUploading = false);
    }
  }

  Future<LeaveFormAttachmentMetadata> _readLeaveFormMetadata() async {
    final result = await controller.runJavaScriptReturningResult('''
(() => {
  const valueOf = (names) => {
    for (const name of names) {
      const element = document.getElementById(name)
        || document.querySelector(`[name="\${name}" i]`)
        || document.querySelector(`[id="\${name}" i]`);
      const value = element?.value ?? element?.getAttribute?.('value') ?? '';
      if (String(value).trim()) return String(value).trim();
    }
    return '';
  };
  return JSON.stringify({
    docUnid: valueOf(['WF_DocUnid']),
    processId: valueOf(['WF_Processid', 'WF_ProcessId']),
    nodeName: valueOf(['WF_CurrentNodeName']),
    // 学校附件 iframe 不读取该字段值，只以元素是否存在决定 localStore。
    // 新建单据常见 value 为空，但 iframe 仍会上传 1。
    localStore: document.getElementById('localStore') ? '1' : '0'
  });
})()
''');
    return parseLeaveFormAttachmentMetadata(result);
  }

  Future<LeaveFormAttachmentMetadata> _waitForLeaveFormMetadata() async {
    return waitForLeaveFormAttachmentMetadata(
      maximumAttempts: 40,
      retryInterval: const Duration(milliseconds: 500),
      readMetadata: _readLeaveFormMetadata,
      wait: _waitForMetadataRetry,
    );
  }

  Future<void> _waitForMetadataRetry(Duration duration) {
    return Future<void>.delayed(duration);
  }

  Future<void> _unlockLeaveSubmissionGate() {
    return controller.runJavaScript(
      'window.__gzusLeaveSubmissionGate?.unlock();',
    );
  }

  String _leaveAutomationErrorMessage(Object error) {
    if (error is StateError || error is FormatException) {
      return error.toString();
    }
    if (error is ApiException) return '附件上传失败：${error.message}';
    return '自动填写或附件上传失败，请重试';
  }

  Future<void> _retryLeaveAttachmentUpload() async {
    if (attachmentsUploading || attachmentsUploaded) return;
    try {
      await _uploadLeaveAttachments();
      if (mounted) {
        setState(() => loadError = null);
      }
    } catch (exc) {
      if (mounted) {
        setState(() => loadError = _leaveAutomationErrorMessage(exc));
      }
    }
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
    await _injectSchoolCookies(widget.api, uri);
    final authToken = widget.api.ehallAuthToken;
    if (isEhallHost(uri.host) &&
        widget.fillScript == null &&
        authToken != null &&
        authToken.isNotEmpty) {
      // 先在 ehall 同源页面写入前端登录态，避免业务页首次加载即跳转登录。
      _pendingUserLoginToken = authToken;
      _pendingTargetUrl = uri;
      await _loadUrl(Uri.parse('https://ehall.gzus.edu.cn/'));
      _schedulePrimeFallback();
      return;
    }
    await _loadUrl(uri);
  }

  Future<void> _handlePageFinished(String urlString) async {
    final token = _pendingUserLoginToken;
    if (token == null) return;
    final uri = Uri.tryParse(urlString);
    if (uri == null || !isEhallHost(uri.host)) return;
    _pendingUserLoginToken = null;
    final target = _pendingTargetUrl;
    _pendingTargetUrl = null;
    await _writeUserLoginToken(token);
    if (target != null) {
      await _loadUrl(target);
    }
  }

  /// 若 ehall 首页长时间未完成（例如被重定向到统一认证），仍继续打开目标页。
  void _schedulePrimeFallback() {
    unawaited(Future<void>.delayed(const Duration(seconds: 8), () async {
      if (!mounted || _pendingUserLoginToken == null) return;
      final target = _pendingTargetUrl;
      _pendingUserLoginToken = null;
      _pendingTargetUrl = null;
      if (target != null) {
        await _loadUrl(target);
      }
    }));
  }

  Future<void> _loadUrl(Uri uri) async {
    final authToken = widget.api.ehallAuthToken;
    final headers = <String, String>{
      if (isEhallHost(uri.host) && authToken != null && authToken.isNotEmpty)
        'Authorization': authToken,
    };
    try {
      await controller.loadRequest(uri, headers: headers);
    } catch (_) {
      // 加载失败统一由 onWebResourceError 提示，页内可随时跳转外部浏览器。
    }
  }

  Future<void> _writeUserLoginToken(String authToken) async {
    try {
      await controller.runJavaScript('''
(() => {
  try {
    const payload = JSON.stringify({ tokenId: ${jsonEncode(authToken)} });
    sessionStorage.setItem('userLogin', payload);
    localStorage.setItem('userLogin', payload);
  } catch (e) {}
})()
''');
    } catch (_) {}
  }

  Future<void> _injectSchoolCookies(ApiClient api, Uri targetUri) async {
    await _injectCookieHeader(api.ehallCookies, ehallCookieDomains(targetUri));
    await _injectCookieHeader(api.jwxtCookies, jwxtCookieDomains(targetUri));
  }

  Future<void> _injectCookieHeader(
    String? header,
    List<String> domains,
  ) async {
    if (header == null || header.isEmpty) return;
    final cookies = parseCookieHeader(header);
    if (cookies.isEmpty) return;
    for (final domain in domains) {
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

  Future<void> _openInExternalBrowser() async {
    if (widget.attachments.isNotEmpty && !attachmentsUploaded) return;
    final currentUrl = await controller.currentUrl();
    final uri = Uri.tryParse(currentUrl ?? widget.initialUrl);
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
          IconButton(
            tooltip: '浏览器打开',
            onPressed: widget.attachments.isNotEmpty && !attachmentsUploaded
                ? null
                : _openInExternalBrowser,
            icon: const Icon(Icons.open_in_new),
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
                if (widget.attachments.isNotEmpty && !attachmentsUploaded)
                  TextButton(
                    onPressed: attachmentsUploading
                        ? null
                        : _retryLeaveAttachmentUpload,
                    child: const Text('重试上传'),
                  ),
                TextButton(
                  onPressed:
                      widget.fillScript == null || widget.fillScript!.isEmpty
                          ? null
                          : _copyFillScript,
                  child: const Text('复制脚本'),
                ),
                if (widget.attachments.isEmpty || attachmentsUploaded)
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
