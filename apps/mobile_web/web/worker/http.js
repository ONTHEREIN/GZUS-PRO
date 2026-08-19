// HTTP 辅助 + 响应工具（自 _worker.js 拆分）。
// fetchWithCookies（手动重定向带 cookie）、GBK/UTF-8 智能解码、
// vercelOrigin、诊断鉴权、corsHeaders/jsonResponse/errorResponse。
// 无跨模块依赖（仅全局 fetch/Headers/TextDecoder）。
// ─── Fetch with cookie management ──────────────────────────────────
async function fetchWithCookies(url, options = {}, jar) {
  const maxRedirects = 10;
  let currentUrl = url;
  let currentOptions = { ...options };

  for (let i = 0; i < maxRedirects; i++) {
    const parsedUrl = new URL(currentUrl);
    const host = parsedUrl.hostname;

    // Add cookies from jar
    const cookieHeader = jar.getHeaderForHost(host);
    const headers = new Headers(currentOptions.headers || {});
    if (cookieHeader) {
      headers.set('Cookie', cookieHeader);
    }
    if (!headers.has('User-Agent')) {
      headers.set('User-Agent', 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0');
    }

    // Use manual redirect so we can attach cookies to each hop
    const response = await fetch(currentUrl, { ...currentOptions, headers, redirect: 'manual' });

    // Collect cookies from response
    jar.addFromResponse(currentUrl, response);

    // Check for redirect
    const status = response.status;
    if (status >= 300 && status < 400) {
      const location = response.headers.get('location');
      if (location) {
        currentUrl = new URL(location, currentUrl).href;
        // Follow redirect as GET (drop body and method)
        currentOptions = { method: 'GET', headers: {} };
        continue;
      }
    }

    return response;
  }

  throw new Error('Too many redirects');
}

// ─── Encoding-smart decoder for JWXT responses ─────────────────
// JWXT has historically used GBK encoding.  Cloudflare Workers always
// decode fetch responses as UTF-8, which produces garbled text for GBK
// content.  We decode raw bytes manually, trying UTF-8 first (JWXT may
// have switched to UTF-8), falling back to GBK if UTF-8 is invalid.
const gbkDecoder = new TextDecoder('gbk');
function decodeResponse(response) {
  return response.arrayBuffer().then(buf => {
    // Try UTF-8 first — JWXT has been observed using UTF-8 since mid-2026
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(buf);
    } catch (_) {
      // Invalid UTF-8 → fall back to legacy GBK
      return gbkDecoder.decode(buf);
    }
  });
}
async function fetchGbkJson(url, options) {
  const res = await fetch(url, options);
  if (!res.ok) return [res, null];
  const text = await decodeResponse(res);
  try {
    return [res, JSON.parse(text)];
  } catch (e) {
    console.warn(`[gbk] JSON parse failed: ${e.message}`);
    return [res, null];
  }
}
async function fetchGbkText(url, options) {
  const res = await fetch(url, options);
  if (!res.ok) return [res, null];
  const text = await decodeResponse(res);
  return [res, text];
}

// ─── Utility functions ─────────────────────────────────────────────
function vercelOrigin(env) {
  return (env.API_ORIGIN || 'https://api-one-zeta-dc0jrazxzq.vercel.app').replace(/\/$/, '');
}

// 诊断端点（jwxt-test/kv-test）鉴权：未配置 INTERNAL_API_KEY 或 key 不匹配时拒绝访问
function authorizeDiagnostics(request, env) {
  const expected = env && env.INTERNAL_API_KEY;
  if (!expected) return false;
  const provided = request.headers.get('X-Internal-Key');
  return provided === expected;
}

function shouldReturnJwxtCookies(request) {
  const platform = (request.headers.get('X-Client-Platform') || '').toLowerCase();
  return platform === 'android' || platform === 'ios';
}

function corsHeaders(request) {
  return {
    'Access-Control-Allow-Origin': request.headers.get('Origin') || '*',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,PATCH,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Session-Id,X-Client-Platform,X-GZUS-Trace-Id,User-Agent',
    'Access-Control-Max-Age': '86400',
  };
}

function jsonResponse(data, status = 200, request = null) {
  const headers = { 'Content-Type': 'application/json' };
  if (request) {
    Object.assign(headers, corsHeaders(request));
  }
  return new Response(JSON.stringify(data), { status, headers });
}

function errorResponse(message, status = 401, request = null) {
  return jsonResponse({ detail: message }, status, request);
}


export {
  fetchWithCookies,
  fetchGbkJson,
  fetchGbkText,
  vercelOrigin,
  authorizeDiagnostics,
  shouldReturnJwxtCookies,
  corsHeaders,
  jsonResponse,
  errorResponse,
};

