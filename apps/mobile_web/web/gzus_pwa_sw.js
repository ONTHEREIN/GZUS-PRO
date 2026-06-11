const CACHE_NAME = 'gzus-pwa-cache-v2';
const API_CACHE_NAME = 'gzus-api-cache-v1';
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
  '/me',
  '/schedule',
  '/exams',
  '/grades',
  '/attendance',
  '/credits',
  '/notices',
  '/ehall/progress',
  '/ecard/summary',
  '/ecard/consumption',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return Promise.all(
        STATIC_ASSETS.map((asset) =>
          cache.add(asset).catch(() => undefined)
        )
      );
    })
  );
  // Immediately activate the new service worker — don't wait for
  // all tabs to close.  This is critical for Flutter web deployments
  // where stale cached main.dart.js / canvaskit.wasm will break the app.
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
        })
      );
    })
  );
  // Take control of all clients immediately so the new SW handles
  // requests right away (paired with skipWaiting in install).
  event.waitUntil(clients.claim());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') {
    return;
  }
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) {
    return;
  }
  if (API_WHITELIST.some((path) => url.pathname.startsWith(path))) {
    event.respondWith(
      caches.open(API_CACHE_NAME).then((cache) => {
        return cache.match(request).then((cachedResponse) => {
          const fetchPromise = fetch(request).then((networkResponse) => {
            cache.put(request, networkResponse.clone());
            return networkResponse;
          }).catch(() => cachedResponse);
          return cachedResponse || fetchPromise;
        });
      })
    );
  } else {
    // Network-first with cache fallback for static assets.
    // This ensures new deployments (main.dart.js, flutter_bootstrap.js,
    // canvaskit/*) are picked up immediately, while still supporting
    // offline mode via cached fallback.
    event.respondWith(
      fetch(request).then((networkResponse) => {
        // Update cache with fresh response
        const cloned = networkResponse.clone();
        caches.open(CACHE_NAME).then((cache) => {
          cache.put(request, cloned);
        });
        return networkResponse;
      }).catch(() => {
        // Offline — serve from cache
        return caches.match(request);
      })
    );
  }
});

self.addEventListener('push', (event) => {
  const data = event.data ? event.data.json() : {};
  const title = data.title || 'OneGZUS 通知';
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
        return Promise.all(
          cacheNames.map((name) => caches.delete(name))
        );
      })
    );
  }
});
