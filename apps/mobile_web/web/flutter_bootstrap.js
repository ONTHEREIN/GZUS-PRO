{{flutter_js}}
{{flutter_build_config}}

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'GZUS_PUSH_OPEN') {
      window.postMessage(event.data, window.location.origin);
    }
  });

  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('gzus_pwa_sw.js?v=' + {{flutter_service_worker_version}})
      .catch((error) => {
        console.warn('GZUS service worker registration failed:', error);
      });
  });
}

_flutter.loader.load({
  config: {
    canvasKitVariant: 'full',
    canvasKitBaseUrl: 'canvaskit/',
  },
});
