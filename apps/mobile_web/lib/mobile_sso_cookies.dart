/// WebView 学校登录态 Cookie 的域与请求头处理。
bool isGzusHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'gzus.edu.cn' || normalized.endsWith('.gzus.edu.cn');
}

bool isEhallHost(String host) => host.toLowerCase() == 'ehall.gzus.edu.cn';

bool isJwxtHost(String host) => host.toLowerCase() == 'jwxt.gzus.edu.cn';

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
