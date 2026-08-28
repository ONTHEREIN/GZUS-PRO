import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_client.dart';
import 'mobile_sso_cookies.dart';

const _desktopBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

Future<bool> openAuthenticatedEhallUrl(
  BuildContext context,
  String url, {
  String? fillScript,
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
    this.fillScript,
  });

  final String initialUrl;
  final String? fillScript;
  final ApiClient api;

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
            onPressed: _openInExternalBrowser,
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
