import 'package:web/web.dart' as web;

void redirectTo(String url) {
  web.window.location.assign(url);
}

void replaceBrowserUrl(String url) {
  web.window.history.replaceState(null, '', url);
}

String currentBrowserUrl() => web.window.location.href;
