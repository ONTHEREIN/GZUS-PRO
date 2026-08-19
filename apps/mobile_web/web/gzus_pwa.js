// Auto-reload when Service Worker updates to avoid stale cached code
if ('serviceWorker' in navigator) {
  const hadServiceWorkerController = Boolean(navigator.serviceWorker.controller);
  let reloadedForServiceWorkerUpdate = false;

  const reloadForServiceWorkerUpdate = () => {
    if (!hadServiceWorkerController || reloadedForServiceWorkerUpdate) return;
    reloadedForServiceWorkerUpdate = true;
    window.location.reload();
  };

  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'GZUS_SW_UPDATED') {
      console.log('Service Worker updated, reloading page...');
      reloadForServiceWorkerUpdate();
    }
  });
  // Also listen for controller change (new SW taking over)
  navigator.serviceWorker.addEventListener('controllerchange', reloadForServiceWorkerUpdate);
}

initStartupLoading();

window.gzusWebPushInit = function() {
  console.log('GZUS Web Push initialized');
};

window.gzusWebPushIsSupported = function() {
  return 'serviceWorker' in navigator &&
         'PushManager' in window &&
         'Notification' in window &&
         window.isSecureContext;
};

window.gzusWebPushIsSubscribed = async function(callback) {
  try {
    const swReg = await navigator.serviceWorker.ready;
    const subscription = await swReg.pushManager.getSubscription();
    callback(subscription !== null);
  } catch (e) {
    callback(false);
  }
};

window.gzusWebPushGetPermissionStatus = function() {
  try {
    if (typeof Notification === 'undefined') return 'denied';
    return Notification.permission;
  } catch (e) {
    return 'denied';
  }
};

window.gzusWebPushRequestPermission = async function(callback) {
  try {
    const permission = await Notification.requestPermission();
    callback(permission === 'granted');
  } catch (e) {
    callback(false);
  }
};

window.gzusWebPushSubscribe = async function(publicKey, apiBaseUrl, sessionId, callback) {
  try {
    const swReg = await navigator.serviceWorker.ready;
    const subscription = await swReg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(publicKey),
    });
    
    const keys = {
      p256dh: uint8ArrayToBase64Url(subscription.getKey('p256dh')),
      auth: uint8ArrayToBase64Url(subscription.getKey('auth')),
    };
    
    const response = await fetch(apiUrl(apiBaseUrl, '/push/web/register'), {
      method: 'POST',
      headers: requestHeaders(sessionId),
      body: JSON.stringify({
        endpoint: subscription.endpoint,
        keys: keys,
        expirationTime: subscription.expirationTime,
      }),
    });
    if (!response.ok) {
      await subscription.unsubscribe();
      throw new Error(`Web push register failed: ${response.status}`);
    }
    callback(true);
  } catch (e) {
    callback(false);
  }
};

window.gzusWebPushUnsubscribe = async function(apiBaseUrl, sessionId, callback) {
  try {
    const swReg = await navigator.serviceWorker.ready;
    const subscription = await swReg.pushManager.getSubscription();
    if (subscription) {
      await subscription.unsubscribe();
    }
    await fetch(apiUrl(apiBaseUrl, '/push/web/unregister'), {
      method: 'POST',
      headers: requestHeaders(sessionId),
    });
    callback(true);
  } catch (e) {
    console.error('Unsubscribe failed:', e);
    callback(false);
  }
};

window.gzusWebPushClearCache = async function() {
  try {
    const cacheNames = await caches.keys();
    for (const name of cacheNames) {
      await caches.delete(name);
    }
  } catch (e) {
    console.error('Clear cache failed:', e);
  }
};

window.gzusWebPushSetOnTap = function(callback) {
  window.addEventListener('message', function(event) {
    if (event.data && event.data.type === 'GZUS_PUSH_OPEN') {
      callback(event.data.extras || {});
    }
  });
};

function urlBase64ToUint8Array(base64Url) {
  let base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4 !== 0) {
    base64 += '=';
  }
  const rawData = window.atob(base64);
  const array = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; i++) {
    array[i] = rawData.charCodeAt(i);
  }
  return array;
}

function uint8ArrayToBase64Url(array) {
  const base64 = window.btoa(String.fromCharCode(...array));
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function apiUrl(apiBaseUrl, path) {
  const base = String(apiBaseUrl || '').replace(/\/$/, '');
  if (!base) {
    return path;
  }
  return `${base}${path}`;
}

function requestHeaders(sessionId) {
  const headers = { 'Content-Type': 'application/json' };
  if (sessionId) {
    headers['X-Session-Id'] = sessionId;
  }
  return headers;
}

function initStartupLoading() {
  const container = document.getElementById('loading-container');
  if (!container) return;

  const title = document.getElementById('loading-title');
  const hint = document.getElementById('loading-hint');
  const refresh = document.getElementById('loading-refresh');
  const clearCache = document.getElementById('loading-clear-cache');
  const appName = startupAppName();
  let firstFrameArrived = false;
  let slowTimer = null;
  let fallbackTimer = null;
  let recoveryTimer = null;
  let flutterViewTimer = null;

  const setText = (nextTitle, nextHint) => {
    if (title) title.textContent = nextTitle;
    if (hint) hint.textContent = nextHint;
  };
  const getRecoveredFlag = () => {
    try {
      return window.sessionStorage?.getItem('gzus_startup_recovered') === '1';
    } catch (_) {
      return false;
    }
  };
  const setRecoveredFlag = () => {
    try {
      window.sessionStorage?.setItem('gzus_startup_recovered', '1');
    } catch (_) {}
  };
  const clearRecoveredFlag = () => {
    try {
      window.sessionStorage?.removeItem('gzus_startup_recovered');
    } catch (_) {}
  };
  const finishLoading = () => {
    if (firstFrameArrived) return;
    firstFrameArrived = true;
    window.clearTimeout(slowTimer);
    window.clearTimeout(fallbackTimer);
    window.clearTimeout(recoveryTimer);
    window.clearInterval(flutterViewTimer);
    clearRecoveredFlag();
    container.classList.add('fade-out');
    window.setTimeout(() => container.remove(), 300);
  };
  const hasFlutterView = () => Boolean(document.querySelector(
    'flutter-view, flt-glass-pane, flt-scene-host, flt-semantics-host'
  ));

  setText(`${appName}加载中...`, '正在准备校园服务');
  applyStartupTitle(appName);

  slowTimer = window.setTimeout(() => {
    if (firstFrameArrived) return;
    setText(`${appName}仍在加载...`, '如果长时间停在这里，可能是网络或缓存版本未更新');
  }, 12000);

  fallbackTimer = window.setTimeout(() => {
    if (firstFrameArrived) return;
    container.classList.add('needs-help');
    setText(`${appName}加载时间过长`, '请先刷新；如果仍无响应，清缓存并刷新');
  }, 25000);

  recoveryTimer = window.setTimeout(async () => {
    if (firstFrameArrived) return;
    if (getRecoveredFlag()) return;
    try {
      setRecoveredFlag();
      container.classList.add('needs-help');
      setText('正在修复加载状态...', '将清理旧缓存并自动刷新一次');
      await clearStartupCache();
      window.location.replace(cacheBustedUrl());
    } catch (_) {
      container.classList.add('needs-help');
      setText(`${appName}加载时间过长`, '请点击清缓存并刷新');
    }
  }, 30000);

  if (refresh) {
    refresh.addEventListener('click', () => {
      window.location.reload();
    });
  }

  if (clearCache) {
    clearCache.addEventListener('click', async () => {
      setText('正在清理缓存...', '清理完成后会自动刷新');
      clearCache.disabled = true;
      if (refresh) refresh.disabled = true;
      await clearStartupCache();
      window.location.replace(cacheBustedUrl());
    });
  }

  window.addEventListener('flutter-first-frame', finishLoading, { once: true });

  flutterViewTimer = window.setInterval(() => {
    if (hasFlutterView()) {
      window.setTimeout(finishLoading, 400);
    }
  }, 250);

  window.addEventListener('error', () => {
    if (firstFrameArrived) return;
    container.classList.add('needs-help');
    setText(`${appName}加载失败`, '请刷新；如果重复失败，清缓存并刷新');
  });
}

function startupAppName() {
  const configuredMode = document
    .querySelector('meta[name="gzus-build-mode"]')
    ?.getAttribute('content')
    ?.trim()
    .toLowerCase();
  const hostname = window.location.hostname;
  const isLocal = hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname === '[::1]' ||
    hostname.endsWith('.local');
  const mode = configuredMode && configuredMode !== 'auto'
    ? configuredMode
    : (isLocal ? 'debug' : 'release');

  if (mode === 'debug' || mode === 'dev' || mode === 'development') {
    return '软帮手';
  }
  if (mode === 'profile' || mode === 'preview' || mode === 'staging') {
    return '软帮手预览版';
  }
  return '软帮手';
}

function applyStartupTitle(appName) {
  document.title = appName === '软帮手'
    ? '软帮手 | OneGZUS'
    : `${appName} | OneGZUS`;
  const appleTitle = document.querySelector('meta[name="apple-mobile-web-app-title"]');
  if (appleTitle) appleTitle.setAttribute('content', appName);
  const description = document.querySelector('meta[name="description"]');
  if (description) description.setAttribute('content', `${appName} OneGZUS`);
}

async function clearStartupCache() {
  const tasks = [];
  if ('caches' in window) {
    tasks.push(
      caches.keys()
        .then((names) => Promise.all(names.map((name) => caches.delete(name))))
        .catch((e) => console.error('Clear startup cache failed:', e))
    );
  }
  if ('serviceWorker' in navigator) {
    tasks.push(
      navigator.serviceWorker.getRegistrations()
        .then((registrations) => Promise.all(registrations.map((item) => item.unregister())))
        .catch((e) => console.error('Unregister service worker failed:', e))
    );
  }
  await Promise.all(tasks);
}

function cacheBustedUrl() {
  const url = new URL(window.location.href);
  url.searchParams.set('reload', Date.now().toString());
  return url.toString();
}
