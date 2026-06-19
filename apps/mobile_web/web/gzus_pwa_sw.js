const CACHE_NAME = 'gzus-pwa-cache-v4';
const API_CACHE_NAME = 'gzus-api-cache-v2';
const API_CACHE_MAX_AGE_MS = 5 * 60 * 1000;
const STATIC_ASSETS = [
  './',
  './index.html',
  './flutter_bootstrap.js',
  './main.dart.js',
  './canvaskit/canvaskit.js',
  './canvaskit/canvaskit.wasm',
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

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return Promise.all(
        STATIC_ASSETS.map((asset) => cache.add(asset).catch(() => undefined))
      );
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((name) => {
          if (name !== CACHE_NAME && name !== API_CACHE_NAME) {
            return caches.delete(name);
          }
          return undefined;
        })
      );
    })
  );
  event.waitUntil(
    Promise.all([
      self.registration.navigationPreload?.disable?.().catch(() => undefined),
      clients.claim(),
    ])
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

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
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(APP_SHELL_URL) || await cache.match(request);

  if (cached) {
    revalidateStaticRequest(request, cache, APP_SHELL_URL);
    return cached;
  }

  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putStaticResponse(cache, APP_SHELL_URL, networkResponse);
    return networkResponse;
  } catch (_) {
    return Response.error();
  }
}

async function handleStaticRequest(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);

  if (cached) {
    revalidateStaticRequest(request, cache, request);
    return cached;
  }

  try {
    const networkResponse = await fetch(request, { cache: 'no-store' });
    await putStaticResponse(cache, request, networkResponse);
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

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'GZUS_CLEAR_CACHE') {
    event.waitUntil(
      caches.keys().then((cacheNames) => {
        return Promise.all(cacheNames.map((name) => caches.delete(name)));
      })
    );
  }
});
