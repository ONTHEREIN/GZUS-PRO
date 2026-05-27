import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _lyMobileSsoUrl =
    'https://cas.gzus.edu.cn/lyuapServer/login?service=https%3A%2F%2Fjwxt.seig.edu.cn%2Fsso%2Flyiotlogin';
const _jwxtCookieUrls = [
  'https://jwxt.seig.edu.cn',
  'https://jwxt.seig.edu.cn/',
  'https://jwxt.seig.edu.cn/sso/lyiotlogin',
  'https://jwxt.seig.edu.cn/jwglxt/',
  'https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html',
];

class MobileCookieLoginResult {
  const MobileCookieLoginResult({required this.account, required this.cookies});

  final String account;
  final String cookies;
}

class MobileSsoLoginPage extends StatefulWidget {
  const MobileSsoLoginPage({super.key, required this.account});

  final String account;

  @override
  State<MobileSsoLoginPage> createState() => _MobileSsoLoginPageState();
}

class _MobileSsoLoginPageState extends State<MobileSsoLoginPage> {
  final cookieManager = WebViewCookieManager();
  WebViewController? controller;
  bool finishing = false;
  bool cookiesCleared = false;
  String statusText = '正在打开办事大厅登录页面';
  String? error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await cookieManager.clearCookies();
      cookiesCleared = false;
      final nextController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (url) => _observeUrl(url, pageFinished: false),
            onPageFinished: (url) => _observeUrl(url, pageFinished: true),
            onUrlChange: (change) {
              final url = change.url;
              if (url != null) _observeUrl(url, pageFinished: false);
            },
            onWebResourceError: (webError) {
              if (!mounted || finishing) return;
              setState(() => error = '登录页面加载失败：${webError.description}');
            },
          ),
        )
        ..loadRequest(Uri.parse(_lyMobileSsoUrl));
      if (!mounted) return;
      setState(() {
        controller = nextController;
        error = null;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() => error = '无法打开登录页面：$exc');
    }
  }

  void _observeUrl(String url, {required bool pageFinished}) {
    final uri = Uri.tryParse(url);
    if (!mounted || uri == null || finishing) {
      return;
    }
    if (uri.host == 'cas.gzus.edu.cn') {
      setState(() => statusText = '请在办事大厅页面完成登录');
      if (pageFinished) _prefillCasAccount();
      return;
    }
    if (uri.host == 'jwxt.seig.edu.cn') {
      setState(() => statusText = '正在进入教务系统');
    }
    if (uri.host == 'jwxt.seig.edu.cn' && pageFinished) {
      _handleJwxtUrl(url);
    }
  }

  Future<void> _prefillCasAccount() async {
    final currentController = controller;
    if (currentController == null) return;
    final account = jsonEncode(widget.account);
    for (var attempt = 0; attempt < 12; attempt++) {
      if (finishing || !mounted) return;
      try {
        final result = await currentController.runJavaScriptReturningResult('''
(() => {
  const input = document.getElementById('userName')
    || document.querySelector('input[name="username"], input[type="text"]');
  if (!input) return false;
  if (input.value) return true;
  input.value = $account;
  input.dispatchEvent(new Event('input', {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  return input.value === $account;
})();
''');
        if (result == true || result.toString() == 'true') return;
      } catch (_) {
        // The CAS page can still be used manually when script injection is blocked.
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> _handleJwxtUrl(String url) async {
    if (finishing) return;
    finishing = true;
    if (mounted) {
      setState(() {
        statusText = '正在获取教务系统登录状态';
        error = null;
      });
    }
    try {
      final cookieHeader = await _readJwxtCookies(url);
      if (cookieHeader.isEmpty) {
        throw StateError('未获取到教务系统 cookie');
      }
      await _clearTemporaryCookies();
      if (!mounted) return;
      Navigator.of(context).pop(
        MobileCookieLoginResult(account: widget.account, cookies: cookieHeader),
      );
    } catch (exc) {
      finishing = false;
      if (!mounted) return;
      setState(() => error = '获取教务系统 cookie 失败：$exc');
    }
  }

  Future<String> _readJwxtCookies(String currentUrl) async {
    final urls = <String>[
      currentUrl,
      ..._jwxtCookieUrls,
    ];
    for (var attempt = 0; attempt < 6; attempt++) {
      final cookiesByName = <String, String>{};
      for (final url in urls) {
        final uri = Uri.tryParse(url);
        if (uri == null) continue;
        final cookies = await cookieManager.platform.getCookies(uri);
        for (final cookie in cookies) {
          if (cookie.name.isNotEmpty && cookie.value.isNotEmpty) {
            cookiesByName[cookie.name] = cookie.value;
          }
        }
      }
      final scriptCookies = await _readDocumentCookies();
      for (final entry in scriptCookies.entries) {
        cookiesByName.putIfAbsent(entry.key, () => entry.value);
      }
      final cookieHeader = _selectCookieHeader(cookiesByName);
      if (cookieHeader.isNotEmpty) return cookieHeader;
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return '';
  }

  Future<Map<String, String>> _readDocumentCookies() async {
    final currentController = controller;
    if (currentController == null) return const {};
    try {
      final value = await currentController
          .runJavaScriptReturningResult('document.cookie');
      return _parseCookieString(_normalizeJavaScriptString(value));
    } catch (_) {
      return const {};
    }
  }

  String _selectCookieHeader(Map<String, String> cookies) {
    MapEntry<String, String>? jsession;
    for (final entry in cookies.entries) {
      if (entry.key.toUpperCase() == 'JSESSIONID') {
        jsession = entry;
        break;
      }
    }
    final entries = [
      if (jsession != null) jsession,
      ...cookies.entries
          .where((entry) => entry.key.toUpperCase() != 'JSESSIONID'),
    ];
    return entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  }

  Map<String, String> _parseCookieString(String value) {
    final cookies = <String, String>{};
    for (final part in value.split(';')) {
      final trimmed = part.trim();
      final separator = trimmed.indexOf('=');
      if (separator <= 0 || separator == trimmed.length - 1) continue;
      cookies[trimmed.substring(0, separator)] =
          trimmed.substring(separator + 1);
    }
    return cookies;
  }

  String _normalizeJavaScriptString(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        return jsonDecode(text) as String;
      } catch (_) {
        return text.substring(1, text.length - 1).replaceAll(r'\"', '"');
      }
    }
    return text;
  }

  Future<void> _clearTemporaryCookies() async {
    if (cookiesCleared) return;
    cookiesCleared = true;
    await cookieManager.clearCookies();
  }

  @override
  void dispose() {
    if (!cookiesCleared) {
      cookieManager.clearCookies();
      cookiesCleared = true;
    }
    super.dispose();
  }

  Future<void> _retry() async {
    if (finishing) return;
    setState(() {
      error = null;
      statusText = '正在重新打开办事大厅登录页面';
    });
    await _start();
  }

  void _cancel() {
    _clearTemporaryCookies();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final currentController = controller;
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('办事大厅统一登录'),
        leading: IconButton(
          icon: const Icon(FluentIcons.back),
          onPressed: _cancel,
        ),
        commandBar: error == null
            ? null
            : Button(
                onPressed: _retry,
                child: const _SsoButtonLabel(
                  icon: FluentIcons.refresh,
                  label: '重试',
                ),
              ),
      ),
      content: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: InfoBar(
              severity:
                  error == null ? InfoBarSeverity.info : InfoBarSeverity.error,
              title: Text(error ?? statusText),
            ),
          ),
          Expanded(
            child: currentController == null
                ? const Center(child: ProgressRing())
                : WebViewWidget(controller: currentController),
          ),
        ],
      ),
    );
  }
}

class _SsoButtonLabel extends StatelessWidget {
  const _SsoButtonLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
