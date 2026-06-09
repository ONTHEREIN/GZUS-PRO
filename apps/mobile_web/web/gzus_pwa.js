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
