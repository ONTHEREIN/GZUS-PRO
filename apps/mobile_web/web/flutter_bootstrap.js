{{flutter_js}}
{{flutter_build_config}}

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'GZUS_PUSH_OPEN') {
      window.postMessage(event.data, window.location.origin);
    }
  });
}

const serviceWorkerVersion = {{flutter_service_worker_version}};
const isLocalDevelopment = ['127.0.0.1', 'localhost', '::1'].includes(
  window.location.hostname,
);

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
  // `flutter run` 将版本占位符替换为 null。此时若注册 PWA Worker，
  // 会劫持 DDC 调试模块请求并使 Web 启动卡在加载页。
  serviceWorkerSettings: serviceWorkerVersion == null || isLocalDevelopment
      ? undefined
      : {
          serviceWorkerUrl: 'gzus_pwa_sw.js?v=' + serviceWorkerVersion,
          serviceWorkerVersion,
        },
});
