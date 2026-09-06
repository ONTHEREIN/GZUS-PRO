const CACHE_VERSION = new URL(self.location.href).searchParams.get('v');
if (!CACHE_VERSION) {
  throw new Error('Missing Flutter service worker version');
}
const CACHE_NAME = `gzus-pwa-cache-${CACHE_VERSION}`;
const STAGING_CACHE_NAME = `${CACHE_NAME}-staging`;
const API_CACHE_NAME = 'gzus-api-cache-v2';
const API_CACHE_MAX_AGE_MS = 5 * 60 * 1000;
const STATIC_ASSETS = [
  './',
  './index.html',
  './flutter_bootstrap.js',
  './main.dart.js',
  './gzus_pwa_sw.js',
  './canvaskit/canvaskit.js',
  './canvaskit/canvaskit.wasm',
  './canvaskit/chromium/canvaskit.js',
  './canvaskit/chromium/canvaskit.wasm',
  './manifest.json',
  './gzus_pwa.js',
  './icons/Icon-192.png',
  './icons/icon-192x192.png',
  './icons/icon-512x512.png',
];
const API_WHITELIST = [
  '/api/me',
  '/api/schedule',
  '/api/exams',
  '/api/grades',
  '/api/attendance',
  '/api/credits',
  '/api/ehall/progress',
  '/api/ecard/summary',
  '/api/ecard/consumption',
];
const NETWORK_FIRST_API_PATHS = [
  '/api/notices',
];
const APP_SHELL_URL = './index.html';
const PRECACHE_READY_URL = './__gzus_pwa_precache_ready__';
let precacheInFlight = null;

self.addEventListener('install', (event) => {
  // 安装阶段只下载 Worker 本身，避免与 Flutter 首屏争抢带宽。
  // 首帧后由页面发送 GZUS_PRECACHE_SHELL，再完整准备离线资源。
  event.waitUntil(Promise.resolve());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      // 资源未完整预缓存时保留旧版本，避免失败更新破坏离线启动。
      if (await cache.match(PRECACHE_READY_URL)) {
        const cacheNames = await caches.keys();
        await Promise.all(cacheNames.map((name) => {
          if (name.startsWith('gzus-pwa-cache-') &&
              name !== CACHE_NAME &&
              name !== STAGING_CACHE_NAME) {
            return caches.delete(name);
          }
          return undefined;
        }));
      }
      return clients.claim();
    })
  );
});

self.addEventListener('message', (event) => {
  const type = event.data?.type;
  if (type === 'GZUS_PRECACHE_SHELL') {
    const notifyUpdate = event.data?.notifyUpdate === true;
    event.waitUntil(
      precacheAppShell()
        .then(() => {
          if (notifyUpdate) {
            return notifyClients({ type: 'GZUS_SW_UPDATE_READY' });
          }
          return undefined;
        })
        .catch((error) => {
          console.error('PWA shell precache failed:', error);
        })
    );
    return;
  }

  if (type === 'GZUS_ACTIVATE_UPDATE') {
    self.skipWaiting();
    return;
  }

  if (type === 'GZUS_CLEAR_CACHE') {
    event.waitUntil(
      caches.keys().then((cacheNames) => {
        return Promise.all(cacheNames.map((name) => caches.delete(name)));
      })
    );
  }
});

async function precacheAppShell() {
  if (precacheInFlight) return precacheInFlight;
  precacheInFlight = precacheAppShellOnce();
  try {
    return await precacheInFlight;
  } finally {
    precacheInFlight = null;
  }
}

async function precacheAppShellOnce() {
  const target = await caches.open(CACHE_NAME);
  if (await target.match(PRECACHE_READY_URL)) return;

  await caches.delete(STAGING_CACHE_NAME);
  const staging = await caches.open(STAGING_CACHE_NAME);
  try {
    await Promise.all(STATIC_ASSETS.map(async (asset) => {
      const request = new Request(new URL(asset, self.location).toString(), {
        cache: 'reload',
      });
      const response = await fetch(request);
      if (!response.ok) {
        throw new Error(`PWA asset ${asset} returned HTTP ${response.status}`);
      }
      await staging.put(request, response);
    }));

    await staging.put(PRECACHE_READY_URL, new Response('ready'));
    const stagedRequests = await staging.keys();
    for (const request of stagedRequests) {
      const response = await staging.match(request);
      if (!response) {
        throw new Error(`PWA staging asset missing: ${request.url}`);
      }
      await target.put(request, response);
    }
    await caches.delete(STAGING_CACHE_NAME);
  } catch (error) {
    await caches.delete(STAGING_CACHE_NAME);
    // 新版本缓存未完成时绝不能破坏同版本已有的可用离线壳。
    if (!(await target.match(PRECACHE_READY_URL))) {
      await caches.delete(CACHE_NAME);
    }
    throw error;
  }
}

async function notifyClients(message) {
  const clientList = await clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });
  clientList.forEach((client) => client.postMessage(message));
}

async function readyStaticCache() {
  const current = await caches.open(CACHE_NAME);
  if (await current.match(PRECACHE_READY_URL)) {
    return { cache: current, isCurrent: true };
  }

  const cacheNames = await caches.keys();
  for (const name of cacheNames) {
    if (!name.startsWith('gzus-pwa-cache-') || name.endsWith('-staging')) {
      continue;
    }
    const previous = await caches.open(name);
    if (await previous.match(PRECACHE_READY_URL)) {
      return { cache: previous, isCurrent: false };
    }
  }
  return { cache: current, isCurrent: false };
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname === '/gzus_pwa_sw.js') return;

  if (NETWORK_FIRST_API_PATHS.some((path) => url.pathname.startsWith(path))) {
    event.respondWith(handleApiNetworkFirstRequest(request));
    return;
  }

  if (API_WHITELIST.some((path) => url.pathname.startsWith(path))) {
    event.respondWith(handleApiRequest(request));
    return;
  }

  if (request.mode === 'navigate') {
    event.respondWith(handleNavigationRequest(request));
    return;
  }

  event.respondWith(handleStaticRequest(request));
});

async function handleApiRequest(request) {
  const cache = await caches.open(API_CACHE_NAME);
  const cacheKey = await apiCacheKey(request);
  const cachedResponse = await cache.match(cacheKey);

  if (cachedResponse && isFresh(cachedResponse)) {
    revalidateApiRequest(request, cache, cacheKey);
    return cachedResponse;
  }

  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putApiResponse(cache, cacheKey, networkResponse);
    return networkResponse;
  } catch (error) {
    if (cachedResponse) return cachedResponse;
    throw error;
  }
}

async function handleApiNetworkFirstRequest(request) {
  const cache = await caches.open(API_CACHE_NAME);
  const cacheKey = await apiCacheKey(request);
  const cachedResponse = await cache.match(cacheKey);

  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putApiResponse(cache, cacheKey, networkResponse);
    return networkResponse;
  } catch (error) {
    if (cachedResponse) return cachedResponse;
    throw error;
  }
}

async function revalidateApiRequest(request, cache, cacheKey) {
  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putApiResponse(cache, cacheKey, networkResponse);
  } catch (_) {}
}

async function putApiResponse(cache, cacheKey, response) {
  if (!response || !response.ok) return;
  const headers = new Headers(response.headers);
  headers.set('X-GZUS-Cached-At', Date.now().toString());
  const body = await response.clone().blob();
  const stamped = new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
  await cache.put(cacheKey, stamped);
}

function isFresh(response) {
  const cachedAt = Number(response.headers.get('X-GZUS-Cached-At') || 0);
  return cachedAt > 0 && Date.now() - cachedAt < API_CACHE_MAX_AGE_MS;
}

async function apiCacheKey(request) {
  const url = new URL(request.url);
  const sessionId = request.headers.get('X-Session-Id') || 'anonymous';
  url.searchParams.set('__gzus_cache_session', await shortHash(sessionId));
  return new Request(url.toString(), { method: 'GET' });
}

async function shortHash(value) {
  try {
    const encoded = new TextEncoder().encode(value);
    const digest = await crypto.subtle.digest('SHA-256', encoded);
    return Array.from(new Uint8Array(digest))
      .slice(0, 8)
      .map((byte) => byte.toString(16).padStart(2, '0'))
      .join('');
  } catch (_) {
    return String(value.length);
  }
}

async function handleNavigationRequest(request) {
  const cacheInfo = await readyStaticCache();

  // Network-first for navigation: always try network first to get latest HTML.
  // This prevents stale HTML from serving old main.dart.js references.
  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    if (networkResponse && networkResponse.ok && cacheInfo.isCurrent) {
      await putStaticResponse(cacheInfo.cache, APP_SHELL_URL, networkResponse);
      return networkResponse;
    }
    if (networkResponse && networkResponse.ok) return networkResponse;
  } catch (_) {}

  // Fallback to cache if network fails
  const cached = await cacheInfo.cache.match(APP_SHELL_URL) ||
      await cacheInfo.cache.match(request);
  if (cached) {
    return cached;
  }

  return Response.error();
}

async function handleStaticRequest(request) {
  const cacheInfo = await readyStaticCache();
  const cache = cacheInfo.cache;
  const url = new URL(request.url);

  // canvaskit 目录下的资源（WASM/JS）体积大且随 Flutter 版本发布，
  // 采用 cache-first + 后台再验证策略，避免每次加载都等待网络。
  const isCanvaskitAsset = url.pathname.startsWith('/canvaskit/') ||
                           url.pathname.includes('/canvaskit/');

  if (isCanvaskitAsset) {
    const cached = await cache.match(request);
    if (cached) {
      if (cacheInfo.isCurrent) revalidateStaticRequest(request, cache, request);
      return cached;
    }
    // 首次加载：回退到网络
    try {
      const networkResponse = await fetch(request, { cache: 'no-store' });
      if (cacheInfo.isCurrent) {
        await putStaticResponse(cache, request, networkResponse);
      }
      return networkResponse;
    } catch (_) {
      return Response.error();
    }
  }

  // main.dart.js / flutter_bootstrap.js / manifest.json 等关键脚本：
  // 保持 network-first 以避免部署后使用过期代码。
  const isCriticalAsset = url.pathname.endsWith('.js') ||
                          url.pathname.endsWith('.wasm') ||
                          url.pathname.endsWith('.json');

  if (isCriticalAsset) {
    try {
      const networkResponse = await fetch(request, { cache: 'no-store' });
      if (networkResponse && networkResponse.ok) {
        if (cacheInfo.isCurrent) {
          await putStaticResponse(cache, request, networkResponse);
        }
        return networkResponse;
      }
    } catch (_) {}
  }

  // Cache-first for other assets (icons, fonts, etc.)
  const cached = await cache.match(request);
  if (cached) {
    if (cacheInfo.isCurrent) revalidateStaticRequest(request, cache, request);
    return cached;
  }

  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    if (cacheInfo.isCurrent) {
      await putStaticResponse(cache, request, networkResponse);
    }
    return networkResponse;
  } catch (_) {
    return Response.error();
  }
}

async function revalidateStaticRequest(request, cache, cacheKey) {
  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putStaticResponse(cache, cacheKey, networkResponse);
  } catch (_) {}
}

async function putStaticResponse(cache, cacheKey, response) {
  if (!response || !response.ok) return;
  await cache.put(cacheKey, response.clone());
}

self.addEventListener('push', (event) => {
  const data = event.data ? event.data.json() : {};
  const title = data.title || '软帮手通知';
  const body = data.body || '';
  const extras = data.extras || {};

  const options = {
    body: body,
    icon: './icons/icon-192x192.png',
    badge: './icons/icon-192x192.png',
    data: { extras: extras },
    tag: extras.id || Date.now().toString(),
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const extras = event.notification.data?.extras || {};

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.startsWith(self.location.origin)) {
          client.focus();
          client.postMessage({
            type: 'GZUS_PUSH_OPEN',
            extras: extras,
          });
          return;
        }
      }
      const encodedExtras = encodeURIComponent(JSON.stringify(extras));
      clients.openWindow(`./?pushOpen=${encodedExtras}`);
    })
  );
});
