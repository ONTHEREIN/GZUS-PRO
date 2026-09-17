/// WebView 学校登录态 Cookie 的域与请求头处理。
bool isGzusHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'gzus.edu.cn' || normalized.endsWith('.gzus.edu.cn');
}

bool isEhallHost(String host) => host.toLowerCase() == 'ehall.gzus.edu.cn';

bool isJwxtHost(String host) => host.toLowerCase() == 'jwxt.gzus.edu.cn';

/// 将办事大厅令牌交给其内置的前端 SSO 流程。
///
/// 办事大厅在首屏脚本执行时便会检查 URL 中的 `Authorization` 参数；
/// 若缺失，即使 WebView 已写入 Cookie，也会立刻跳转 CAS。带 hash 的
/// 页面将参数保留在 fragment 内，令牌不会发送到服务端或出现在 Referer 中。
Uri withEhallAuthorization(Uri uri, String authToken) {
  if (uri.fragment.isEmpty) {
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        'Authorization': authToken,
      },
    );
  }
  // 与办事大厅前端的 URL 拼接规则保持一致，兼容入口在 hash 前已有查询参数。
  final separator = uri.toString().contains('?') ? '&' : '?';
  return uri.replace(
    fragment: '${uri.fragment}${separator}Authorization='
        '${Uri.encodeQueryComponent(authToken)}',
  );
}

/// 办事大厅 Cookie 只应写入 ehall 域名，避免把 ehall 会话泄漏给教务系统。
List<String> ehallCookieDomains(Uri targetUri) {
  if (!isGzusHost(targetUri.host)) return const <String>[];
  return const <String>['ehall.gzus.edu.cn'];
}

/// 教务系统 Cookie 只应写入 jwxt 域名。
List<String> jwxtCookieDomains(Uri targetUri) {
  if (!isGzusHost(targetUri.host)) return const <String>[];
  return const <String>['jwxt.gzus.edu.cn'];
}

Map<String, String> parseCookieHeader(String header) {
  final cookies = <String, String>{};
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    final separator = trimmed.indexOf('=');
    if (separator <= 0 || separator == trimmed.length - 1) continue;
    cookies[trimmed.substring(0, separator)] = trimmed.substring(separator + 1);
  }
  return cookies;
}
