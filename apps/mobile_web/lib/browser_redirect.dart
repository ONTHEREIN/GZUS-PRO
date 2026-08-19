import 'browser_redirect_stub.dart'
    if (dart.library.html) 'browser_redirect_web.dart' as impl;

void redirectTo(String url) => impl.redirectTo(url);

void replaceBrowserUrl(String url) => impl.replaceBrowserUrl(url);

String currentBrowserUrl() => impl.currentBrowserUrl();
