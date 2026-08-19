// 静态资源服务（自 _worker.js 拆分）。
// CanvasKit 同变体不跨目录回退、查询串剥离兜底、静态资源缓存头。
// 依赖：corsHeaders（./http.js）+ 自有常量（CANONICAL_APP_ORIGIN/STATIC_ASSET_PATH_RE）。
import { corsHeaders } from './http.js';

const CANONICAL_APP_ORIGIN = 'https://onegzus.cc.cd';
const STATIC_ASSET_PATH_RE = /(?:^\/(?:assets|canvaskit|icons)\/|^\/(?:flutter_bootstrap|flutter|main\.dart|gzus_pwa|gzus_pwa_sw)\.js$|^\/manifest\.json$|^\/version\.json$|^\/favicon\.png$|\.(?:js|mjs|wasm|json|otf|ttf|woff2?|png|jpg|jpeg|webp|gif|svg|ico|css|map)$)/i;

function isStaticAssetPath(pathname) {
  return STATIC_ASSET_PATH_RE.test(pathname);
}

function isHtmlFallback(response) {
  const contentType = response.headers.get('Content-Type') || '';
  return contentType.toLowerCase().includes('text/html');
}

async function fetchAsset(request, env) {
  return env && env.ASSETS ? env.ASSETS.fetch(request) : fetch(request);
}

async function fetchCanonicalStaticAsset(request) {
  const url = new URL(request.url);
  const canonicalUrl = new URL(url.pathname + url.search, CANONICAL_APP_ORIGIN);
  if (url.origin === canonicalUrl.origin) return null;

  try {
    const fallbackRequest = new Request(canonicalUrl.toString(), {
      method: 'GET',
      headers: {
        Accept: request.headers.get('Accept') || '*/*',
      },
    });
    const response = await fetch(fallbackRequest);
    if (response.ok && !isHtmlFallback(response)) return response;
  } catch (e) {
    console.warn(`[asset] canonical fallback failed for ${url.pathname}: ${e.message}`);
  }
  return null;
}

async function fetchQuerylessStaticAsset(request, env) {
  const url = new URL(request.url);
  if (!url.search) return null;
  url.search = '';

  try {
    const assetRequest = new Request(url.toString(), {
      method: 'GET',
      headers: {
        Accept: request.headers.get('Accept') || '*/*',
      },
    });
    const response = await fetchAsset(assetRequest, env);
    if (response.ok && !isHtmlFallback(response)) return response;
  } catch (e) {
    console.warn(`[asset] queryless fallback failed for ${url.pathname}: ${e.message}`);
  }
  return null;
}

async function serveStaticAsset(request, env) {
  const url = new URL(request.url);
  const response = await fetchAsset(request, env);

  if (!isStaticAssetPath(url.pathname)) return response;
  if (response.ok && !isHtmlFallback(response)) {
    return withStaticCacheHeaders(response, url.pathname);
  }

  const queryless = await fetchQuerylessStaticAsset(request, env);
  if (queryless) return withStaticCacheHeaders(queryless, url.pathname);

  const fallback = await fetchCanonicalStaticAsset(request);
  if (fallback) return withStaticCacheHeaders(fallback, url.pathname);

  return new Response(`Static asset not found: ${url.pathname}`, {
    status: response.status >= 400 ? response.status : 404,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
      ...corsHeaders(request),
    },
  });
}

function withStaticCacheHeaders(response, pathname) {
  const headers = new Headers(response.headers);
  if (pathname.startsWith('/canvaskit/')) {
    headers.set('Cache-Control', 'public, max-age=604800, stale-while-revalidate=86400');
  } else if (
    pathname === '/main.dart.js' ||
    pathname === '/flutter_bootstrap.js' ||
    pathname === '/flutter.js' ||
    pathname === '/gzus_pwa.js' ||
    pathname === '/gzus_pwa_sw.js' ||
    /^\/main\.dart\.js_\d+\.part\.js$/.test(pathname)
  ) {
    headers.set('Cache-Control', 'public, max-age=14400, stale-while-revalidate=86400');
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export {
  fetchAsset,
  serveStaticAsset,
};

