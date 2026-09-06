// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html';

StreamSubscription<Event>? _pwaUpdateSubscription;

void clearPwaApiCache() {
  final controller = window.navigator.serviceWorker?.controller;
  controller?.postMessage({'type': 'GZUS_CLEAR_CACHE'});
}

void setPwaUpdateReadyCallback(void Function() callback) {
  clearPwaUpdateReadyCallback();
  final ready = document.documentElement
      ?.attributes['data-gzus-pwa-update-ready'] ==
      '1';
  if (ready) callback();
  _pwaUpdateSubscription = window.on['gzus-pwa-update-ready'].listen((_) {
    callback();
  });
}

void clearPwaUpdateReadyCallback() {
  final subscription = _pwaUpdateSubscription;
  _pwaUpdateSubscription = null;
  if (subscription != null) {
    unawaited(subscription.cancel());
  }
}

Future<void> activatePwaUpdate() async {
  final serviceWorker = window.navigator.serviceWorker;
  if (serviceWorker == null) {
    throw StateError('当前浏览器不支持 Service Worker');
  }
  final registration = await serviceWorker.ready;
  final waiting = registration.waiting;
  if (waiting == null) {
    throw StateError('新版离线资源尚未准备完成，请稍后重试');
  }

  final controllerChanged = Completer<void>();
  final subscription = serviceWorker.on['controllerchange'].listen((_) {
    if (!controllerChanged.isCompleted) {
      controllerChanged.complete();
    }
  });
  waiting.postMessage({'type': 'GZUS_ACTIVATE_UPDATE'});
  try {
    await controllerChanged.future.timeout(const Duration(seconds: 10));
  } finally {
    await subscription.cancel();
  }
  window.location.reload();
}
