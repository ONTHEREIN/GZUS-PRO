{{flutter_js}}
{{flutter_build_config}}

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'GZUS_PUSH_OPEN') {
      window.postMessage(event.data, window.location.origin);
    }
  });
}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
  serviceWorkerSettings: {
    serviceWorkerUrl: 'gzus_pwa_sw.js?v=' + {{flutter_service_worker_version}},
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
