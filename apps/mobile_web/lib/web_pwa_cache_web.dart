// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html';

void clearPwaApiCache() {
  try {
    final controller = window.navigator.serviceWorker?.controller;
    if (controller != null) {
      controller.postMessage({'type': 'GZUS_CLEAR_CACHE'});
    }
  } catch (_) {}
}
