/**
 * GZUS-PRO API Cloudflare Worker
 *
 * Handles CAS SSO login directly on the edge (low latency to China),
 * proxies all other requests to the Vercel backend.
 *
 * Routes handled locally (edge):
 *   POST /auth/auto-login  — full CAS login flow
 *   POST /auth/relogin     — re-login with stored credentials
 *   GET  /health           — health check
 *
 * Routes proxied to Vercel:
 *   Everything else (academic, ehall, ecard, push, etc.)
 */

// ─── RSA Constants (from CAS frontend JS) ──────────────────────────
const RSA_E = 0x010001n;
const RSA_N = BigInt(
  '0x00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5' +
  'fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea' +
  'eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431' +
  '604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117' +
  'e7b1'
);
const RSA_TAG = 'lyasp';

// CAS URLs
const CAS_BASE = 'https://cas.gzus.edu.cn';
const SERVICE_URL = 'https://jwxt.seig.edu.cn/sso/lyiotlogin';
const EHALL_URL = 'https://ehall.gzus.edu.cn';
const JWXT_BASE = 'https://jwxt.seig.edu.cn/jwglxt';

// OCR character fixes for arithmetic captcha
const OCR_CHAR_FIXES = {
  'o': '0', 'O': '0',
  'l': '1', 'I': '1', '|': '1',
  'S': '5', 's': '5',
  'b': '6', 'G': '6',
  'B': '8',
  'g': '9', 'q': '9',
};

const MAX_CAPTCHA_RETRIES = 15;

// ─── RSA Encryption (BigInt.js-style, zero-padded) ─────────────────
function rsaEncrypt(plaintext) {
  const modulusBits = RSA_N.toString(16).length * 4;
  const modulusBytes = Math.ceil(modulusBits / 8);
  const numDigits = Math.floor(modulusBytes / 2);
  const chunkSize = numDigits;
  const hexDigitsPerChunk = numDigits * 4;

  const charCodes = [];
  for (let i = 0; i < plaintext.length; i++) {
    charCodes.push(plaintext.charCodeAt(i));
  }
  while (charCodes.length % chunkSize !== 0) {
    charCodes.push(0);
  }

  const parts = [];
  for (let i = 0; i < charCodes.length; i += chunkSize) {
    let m = 0n;
    for (let r = 0; r < chunkSize / 2; r++) {
      const low = BigInt(charCodes[i + r * 2]);
      const high = BigInt(charCodes[i + r * 2 + 1]);
      const digitVal = low + (high << 8n);
      m += digitVal << BigInt(16 * r);
    }
    const c = modPow(m, RSA_E, RSA_N);
    let hex = c.toString(16);
    while (hex.length < hexDigitsPerChunk) hex = '0' + hex;
    parts.push(hex);
  }
  return parts.join(' ');
}

function modPow(base, exp, mod) {
  let result = 1n;
  base = base % mod;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod;
    exp >>= 1n;
    base = (base * base) % mod;
  }
  return result;
}

// ─── Arithmetic Captcha Solver ─────────────────────────────────────
function solveArithmeticCaptcha(ocrText) {
  for (const text of [ocrText.trim(), fixOcrChars(ocrText.trim())]) {
    const match = text.match(/(\d+)\s*([+\-*/xX×÷])\s*(\d+)/);
    if (!match) continue;
    const a = parseInt(match[1], 10);
    const op = match[2];
    const b = parseInt(match[3], 10);
    if (a > 20 || b > 20 || a === 0 || b === 0) continue;
    const ops = {
      '+': a + b, '-': a - b,
      'x': a * b, 'X': a * b, '*': a * b, '×': a * b,
      '/': Math.floor(a / b), '÷': Math.floor(a / b),
    };
    const result = ops[op];
    if (result !== undefined && result >= 0 && result <= 82) {
      return String(result);
    }
  }
  return null;
}

function fixOcrChars(text) {
  let result = '';
  for (const ch of text) {
    if ('+-*/xX×÷='.includes(ch)) {
      result += ch;
    } else {
      result += OCR_CHAR_FIXES[ch] || ch;
    }
  }
  return result;
}

// ─── Cookie jar (simple) ───────────────────────────────────────────
class CookieJar {
  constructor() {
    this.cookies = new Map(); // domain -> Map(name -> value)
  }

  addFromResponse(url, response) {
    // Cloudflare Workers: use getAll or getSetCookie for multiple set-cookie headers
    let setCookies = [];
    if (typeof response.headers.getAll === 'function') {
      setCookies = response.headers.getAll('set-cookie');
    } else if (typeof response.headers.getSetCookie === 'function') {
      setCookies = response.headers.getSetCookie();
    } else {
      const sc = response.headers.get('set-cookie');
      if (sc) setCookies = [sc];
    }
    const defaultDomain = new URL(url).hostname;
    for (const header of setCookies) {
      this._parseSetCookie(header, defaultDomain);
    }
  }

  _parseSetCookie(header, defaultDomain = '') {
    const parts = header.split(';');
    if (parts.length === 0) return;
    const [nameValue] = parts;
    const eqIdx = nameValue.indexOf('=');
    if (eqIdx === -1) return;
    const name = nameValue.substring(0, eqIdx).trim();
    const value = nameValue.substring(eqIdx + 1).trim();
    // Extract domain from cookie attributes
    let domain = '';
    for (const part of parts.slice(1)) {
      const trimmed = part.trim().toLowerCase();
      if (trimmed.startsWith('domain=')) {
        domain = trimmed.substring(7).replace(/^\./, '');
      }
    }
    if (!domain) domain = defaultDomain;
    if (!domain) return;
    if (!this.cookies.has(domain)) {
      this.cookies.set(domain, new Map());
    }
    this.cookies.get(domain).set(name, value);
  }

  getHeaderForHost(host) {
    const parts = [];
    const hostLower = host.toLowerCase();
    for (const [domain, nameMap] of this.cookies) {
      const domainLower = domain.toLowerCase();
      if (hostLower === domainLower || hostLower.endsWith('.' + domainLower)) {
        for (const [name, value] of nameMap) {
          parts.push(`${name}=${value}`);
        }
      }
    }
    return parts.join('; ');
  }

  getCookiesForDomain(keyword) {
    const parts = [];
    for (const [domain, nameMap] of this.cookies) {
      if (domain.includes(keyword)) {
        for (const [name, value] of nameMap) {
          parts.push(`${name}=${value}`);
        }
      }
    }
    return parts.join('; ');
  }

  getEhallSid() {
    for (const [domain, nameMap] of this.cookies) {
      if (domain.includes('ehall') && nameMap.has('sid')) {
        return nameMap.get('sid');
      }
    }
    return null;
  }
}

// ─── CAS Login Flow ────────────────────────────────────────────────
async function casAutoLogin(account, password, env) {
  const jar = new CookieJar();
  const timeout = 30000;

  // Step 1: GET CAS page to establish session
  let casPageRes;
  for (let retry = 0; retry < 3; retry++) {
    try {
      casPageRes = await fetchWithCookies(
        `${CAS_BASE}/lyuapServer/login?service=${encodeURIComponent(SERVICE_URL)}`,
        { signal: AbortSignal.timeout(timeout) },
        jar
      );
      break;
    } catch (e) {
      if (retry === 2) return { error: `CAS 页面获取失败: ${e.message}` };
      await sleep(500);
    }
  }

  // Step 2-4: Captcha + Login loop
  for (let attempt = 1; attempt <= MAX_CAPTCHA_RETRIES; attempt++) {
    // Step 2: Download kaptcha
    let kaptchaUid = '';
    let captchaBytes = null;
    try {
      const kaptchaRes = await fetchWithCookies(
        `${CAS_BASE}/lyuapServer/kaptcha?_t=${Date.now()}&uid=`,
        { signal: AbortSignal.timeout(timeout) },
        jar
      );
      const data = await kaptchaRes.json();
      kaptchaUid = data.uid || '';
      const content = data.content || '';
      if (content && content.includes(',')) {
        captchaBytes = base64ToUint8Array(content.split(',')[1]);
      } else if (content) {
        captchaBytes = base64ToUint8Array(content);
      }
    } catch (e) {
      return { error: `验证码获取失败: ${e.message}` };
    }

    if (!captchaBytes) {
      return { error: '无法获取验证码图片' };
    }

    // Step 3: OCR captcha
    let captchaCode = null;
    try {
      const ocrResult = await ocrRecognize(captchaBytes, env);
      if (ocrResult) {
        captchaCode = solveArithmeticCaptcha(ocrResult);
      }
    } catch (e) {
      return { error: `验证码识别失败: ${e.message}` };
    }

    if (!captchaCode) continue;

    // Step 4: POST login
    const encryptedPassword = rsaEncrypt(password);
    const timestamp = String(Date.now());
    const token = rsaEncrypt(`${RSA_TAG}${timestamp}`);

    let loginRes;
    try {
      loginRes = await fetchWithCookies(
        `${CAS_BASE}/lyuapServer/v1/tickets`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'token': token,
          },
          body: new URLSearchParams({
            username: account,
            password: encryptedPassword,
            service: SERVICE_URL,
            loginType: '',
            id: kaptchaUid,
            code: captchaCode,
          }),
          redirect: 'manual',
          signal: AbortSignal.timeout(timeout),
        },
        jar
      );
    } catch (e) {
      return { error: `登录请求失败: ${e.message}` };
    }

    if (loginRes.status === 200 || loginRes.status === 201) {
      let respData;
      try {
        respData = await loginRes.json();
      } catch {
        // Try TGT location header
        if (loginRes.status === 201) {
          const location = loginRes.headers.get('location') || '';
          if (location) {
            const tgt = location.split('/').pop();
            try {
              const stRes = await fetchWithCookies(location, {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: new URLSearchParams({ service: SERVICE_URL }),
                signal: AbortSignal.timeout(timeout),
              }, jar);
              if (stRes.ok) {
                const ticket = (await stRes.text()).trim();
                return await finalizeLogin(account, password, ticket, tgt, jar, timeout, env);
              }
            } catch {}
          }
        }
        continue;
      }

      const dataObj = respData.data || {};
      if (typeof dataObj === 'object' && dataObj.code) {
        const err = handleErrorCode(dataObj, kaptchaUid);
        if (err === 'retry') continue;
        return { error: err };
      }

      const ticket = respData.ticket || '';
      const tgt = respData.tgt || '';
      if (ticket) {
        return await finalizeLogin(account, password, ticket, tgt, jar, timeout, env);
      }
    }
  }

  return { error: '验证码识别失败，请重试' };
}

function handleErrorCode(dataObj, uid) {
  const code = dataObj.code || '';
  const messages = {
    'FALSE': '用户名或密码错误',
    'CODEFALSE': 'retry',
    'PASSERROR': dataObj.message || '密码错误',
    'NOUSER': '账号不存在',
    'USERDISABLED': '账号已被禁用',
    'USERLOCK': '账号已被锁定',
    'ISPHONEOREMAILORANSWER': '需要二次验证',
    'ISMODIFYPASS': '需要修改密码',
    'NETWORKCOMMITMENT': '需要网络承诺',
    'PEOPLEMOREACCOUNT': '存在多个关联账号',
  };
  return messages[code] || `登录失败 (${code})`;
}

async function finalizeLogin(account, password, ticket, tgt, jar, timeout, env) {
  // Follow JWXT service ticket + get ehall session in parallel
  const [jwxtResult, ehallResult] = await Promise.allSettled([
    fetchJwxtCookies(ticket, tgt, jar, timeout),
    fetchEhallSession(tgt, jar, timeout),
  ]);

  const jwxtCookies = jwxtResult.status === 'fulfilled' ? jwxtResult.value : '';
  const ehallCookies = ehallResult.status === 'fulfilled' ? ehallResult.value : null;

  // Get student name from JWXT info page
  let studentName = null;
  try {
    const nameResult = await fetchStudentName(jar, timeout);
    if (typeof nameResult === 'object' && nameResult.name) {
      studentName = nameResult.name;
    }
  } catch {}

  // Encrypt credentials
  let credentialToken = null;
  try {
    const key = env.CREDENTIAL_ENCRYPTION_KEY || '';
    if (key) {
      credentialToken = await encryptCredentials(account, password, key);
    }
  } catch {}

  return {
    cookies: jwxtCookies,
    ehallCookies: ehallCookies ? `sid=${ehallCookies}` : null,
    studentName,
    credentialToken,
  };
}

async function fetchJwxtCookies(ticket, tgt, jar, timeout) {
  const redirectUrl = `${SERVICE_URL}?ticket=${ticket}`;
  try {
    await fetchWithCookies(redirectUrl, {
      signal: AbortSignal.timeout(timeout),
    }, jar);
  } catch {}

  let cookies = jar.getCookiesForDomain('jwxt');
  if (!cookies && tgt) {
    // Fallback: request new service ticket
    try {
      const stRes = await fetchWithCookies(
        `${CAS_BASE}/lyuapServer/v1/tickets/${tgt}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ service: SERVICE_URL }),
          signal: AbortSignal.timeout(timeout),
        },
        jar
      );
      if (stRes.ok) {
        const newTicket = (await stRes.text()).trim();
        const newUrl = `${SERVICE_URL}?ticket=${newTicket}`;
        await fetchWithCookies(newUrl, { signal: AbortSignal.timeout(timeout) }, jar);
        cookies = jar.getCookiesForDomain('jwxt');
      }
    } catch {}
  }
  return cookies || '';
}

async function fetchEhallSession(tgt, jar, timeout) {
  if (!tgt) return null;
  const ehallServiceUrl = `${EHALL_URL}/shiro-cas`;
  try {
    const stRes = await fetchWithCookies(
      `${CAS_BASE}/lyuapServer/v1/tickets/${tgt}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ service: ehallServiceUrl }),
        signal: AbortSignal.timeout(timeout),
      },
      jar
    );
    if (stRes.ok) {
      const ehallTicket = (await stRes.text()).trim();
      if (ehallTicket) {
        await fetchWithCookies(
          `${ehallServiceUrl}?ticket=${ehallTicket}`,
          { signal: AbortSignal.timeout(timeout) },
          jar
        );
        return jar.getEhallSid();
      }
    }
  } catch {}
  return null;
}

async function fetchStudentName(jar, timeout) {
  const infoUrl = `${JWXT_BASE}/xsxxxggl/xsgrxxwh_cxXsgrxxIndex.html`;

  try {
    const res = await fetchWithCookies(infoUrl, {
      signal: AbortSignal.timeout(8000),
    }, jar);
    const html = await res.text();
    // Extract name from info page: <p id="col_xm">张三</p>
    let match = html.match(/id="col_xm"[^>]*>\s*<p[^>]*>\s*([^<]+?)\s*<\/p>/);
    if (match && match[1].trim()) return { name: match[1].trim() };
    match = html.match(/id="col_xm"[^>]*>([^<]+)/);
    if (match && match[1].trim()) return { name: match[1].trim() };
    return { name: null };
  } catch {
    return { name: null };
  }
}

// ─── OCR via external API ──────────────────────────────────────────
async function ocrRecognize(imageBytes, env) {
  // Use the Vercel backend's OCR endpoint if available,
  // or fall back to a simple base64 submission
  const vercelOrigin = (env.API_ORIGIN || 'https://api-one-zeta-dc0jrazxzq.vercel.app').replace(/\/$/, '');

  try {
    const b64 = uint8ArrayToBase64(imageBytes);
    const res = await fetch(`${vercelOrigin}/internal/ocr`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Internal-Key': env.INTERNAL_API_KEY || '',
      },
      body: JSON.stringify({ image: b64 }),
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) {
      const data = await res.json();
      return data.text || '';
    }
  } catch {}

  // Fallback: return empty string (captcha will be retried)
  return '';
}

// ─── Credential Encryption/Decryption (Web Crypto AES-GCM) ──────────
async function encryptCredentials(account, password, key) {
  const encoder = new TextEncoder();
  const keyData = await crypto.subtle.digest('SHA-256', encoder.encode(key));
  const cryptoKey = await crypto.subtle.importKey(
    'raw', keyData, { name: 'AES-GCM' }, false, ['encrypt']
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = `${account}:${password}`;
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    cryptoKey,
    encoder.encode(plaintext)
  );
  const combined = new Uint8Array(iv.length + encrypted.byteLength);
  combined.set(iv);
  combined.set(new Uint8Array(encrypted), iv.length);
  return btoa(String.fromCharCode(...combined));
}

async function decryptCredentials(token, key) {
  const encoder = new TextEncoder();
  const keyData = await crypto.subtle.digest('SHA-256', encoder.encode(key));
  const cryptoKey = await crypto.subtle.importKey(
    'raw', keyData, { name: 'AES-GCM' }, false, ['decrypt']
  );
  const combined = Uint8Array.from(atob(token), c => c.charCodeAt(0));
  const iv = combined.slice(0, 12);
  const ciphertext = combined.slice(12);
  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    cryptoKey,
    ciphertext
  );
  const plaintext = new TextDecoder().decode(decrypted);
  const colonIdx = plaintext.indexOf(':');
  if (colonIdx === -1) throw new Error('Invalid credential format');
  return {
    account: plaintext.substring(0, colonIdx),
    password: plaintext.substring(colonIdx + 1),
  };
}

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

// ─── Utility functions ─────────────────────────────────────────────
function base64ToUint8Array(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function uint8ArrayToBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ─── CORS Headers ──────────────────────────────────────────────────
function corsHeaders(request) {
  return {
    'Access-Control-Allow-Origin': request.headers.get('Origin') || '*',
    'Access-Control-Allow-Methods': 'GET,POST,PATCH,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Session-Id,User-Agent',
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

// ─── Session store (memory + Cloudflare KV fallback) ─────────────
// Memory is fast but per-instance.  KV provides cross-instance
// persistence so a Worker cold-start or different colo can still
// inject JWXT cookies (which are IP-bounded to the Worker edge).
const SESSION_KV_TTL = 7200; // 2 hours, matches Vercel session TTL
const localSessions = new Map(); // sessionId -> { cookies, ehallCookies, studentName }

function generateSessionId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

async function saveSessionToKV(sessionId, data, env) {
  if (!env || !env.SESSIONS_KV) {
    return { ok: false, reason: 'env.SESSIONS_KV not available' };
  }
  try {
    const cookiesLen = (data.cookies || '').length;
    const key = `session:${sessionId}`;
    await env.SESSIONS_KV.put(
      key,
      JSON.stringify(data),
      { expirationTtl: SESSION_KV_TTL }
    );
    // Verify the write succeeded by reading it back
    const verify = await env.SESSIONS_KV.get(key);
    if (verify) {
      console.log(`[kv] Session ${sessionId.slice(0, 8)} saved to KV (${cookiesLen} chars cookies)`);
      return { ok: true };
    }
    return { ok: false, reason: 'write appeared to succeed but read-back returned empty' };
  } catch (e) {
    console.warn(`[kv] Failed to save session ${sessionId.slice(0, 8)}:`, e.message);
    return { ok: false, reason: e.message };
  }
}

async function getLocalSession(request, env) {
  const sessionId = request.headers.get('X-Session-Id');
  if (!sessionId) return null;

  // 1. In-memory (same Worker instance that handled login)
  let data = localSessions.get(sessionId);
  if (data) return data;

  // 2. KV fallback (different Worker instance, cold-start, etc.)
  try {
    if (env && env.SESSIONS_KV) {
      const raw = await env.SESSIONS_KV.get(`session:${sessionId}`);
      if (raw) {
        data = JSON.parse(raw);
        localSessions.set(sessionId, data); // cache for subsequent requests
        console.log(`[kv] Session ${sessionId.slice(0, 8)} restored from KV`);
        return data;
      }
    }
  } catch (e) {
    console.warn(`[kv] Failed to restore session ${sessionId.slice(0, 8)}:`, e.message);
  }

  return null;
}

function injectSessionCookies(request, session) {
  const headers = new Headers(request.headers);
  if (session.cookies) {
    console.log(`[inject] Setting Cookie header (${session.cookies.length} chars) for ${request.url}`);
    headers.set('Cookie', session.cookies);
  } else {
    console.warn(`[inject] No JWXT cookies in localSession for ${request.url}`);
  }
  // Store ehall cookies for ehall-specific routes
  if (session.ehallCookies) {
    console.log(`[inject] Setting X-Ehall-Cookies (${session.ehallCookies.length} chars) for ${request.url}`);
    headers.set('X-Ehall-Cookies', session.ehallCookies);
  }
  // Tell Vercel that cookies are injected from the Worker edge.
  // Vercel should skip JWXT cookie validation (IP-bounded cookies).
  headers.set('X-Worker-Auth', '1');
  return new Request(request.url, {
    method: request.method,
    headers,
    body: request.body,
  });
}

// ─── Main Worker Handler ───────────────────────────────────────────
export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    // ─── JWXT proxy for Vercel backend ─────────────────────────
    // Vercel routes JWXT requests through the Worker to preserve the
    // Worker's edge IP (JWXT cookies are IP-bounded).
    const jwxtSessionId = request.headers.get('X-Jwxt-Session-Id');
    if (jwxtSessionId && (url.pathname.startsWith('/jwglxt/') || url.pathname.startsWith('/xtgl/'))) {
      let jwxtCookies = null;
      // Look up cookies in memory first, then KV
      const localData = localSessions.get(jwxtSessionId);
      if (localData && localData.cookies) {
        jwxtCookies = localData.cookies;
      } else {
        try {
          if (env && env.SESSIONS_KV) {
            const raw = await env.SESSIONS_KV.get(`session:${jwxtSessionId}`);
            if (raw) {
              const data = JSON.parse(raw);
              jwxtCookies = data.cookies;
              localSessions.set(jwxtSessionId, data); // cache
            }
          }
        } catch (e) {}
      }
      if (!jwxtCookies) {
        return new Response('JWXT session not found', { status: 502 });
      }
      const jwxtUrl = 'https://jwxt.seig.edu.cn' + url.pathname + url.search;
      try {
        const jwxtRes = await fetch(jwxtUrl, {
          method: request.method,
          headers: {
            'Cookie': jwxtCookies,
            'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
            'Referer': 'https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html',
            ...(request.method === 'POST' ? { 'Content-Type': request.headers.get('Content-Type') || 'application/x-www-form-urlencoded' } : {}),
          },
          body: request.method === 'POST' ? request.body : undefined,
          signal: AbortSignal.timeout(20000),
        });
        const respHeaders = new Headers(jwxtRes.headers);
        respHeaders.set('Access-Control-Allow-Origin', '*');
        return new Response(jwxtRes.body, {
          status: jwxtRes.status,
          headers: respHeaders,
        });
      } catch (e) {
        return new Response('JWXT proxy error: ' + e.message, { status: 502 });
      }
    }

    // API paths: handle in worker or proxy to Vercel
    let path;
    let isApiPath = url.pathname.startsWith('/api/');
    
    if (isApiPath) {
      path = url.pathname.slice(5); // Remove /api/
    } else if (url.pathname.startsWith('/auth/') || 
               url.pathname.startsWith('/health') ||
               url.pathname.startsWith('/academic/') ||
               url.pathname.startsWith('/ehall/') ||
               url.pathname.startsWith('/ecard/') ||
               url.pathname.startsWith('/push/') ||
               url.pathname === '/me' ||
               url.pathname.startsWith('/internal/') ||
               url.pathname.startsWith('/staff/') ||
               url.pathname.startsWith('/leave/') ||
               url.pathname === '/weather' ||
               url.pathname.startsWith('/ws')) {
      // Handle non-/api/ prefixed paths for backward compatibility
      path = url.pathname.slice(1); // Remove leading /
      isApiPath = true;
    }
    
    if (!isApiPath) {
      // Non-API paths: serve static assets directly
      // For HTML pages, explicitly request /index.html from ASSETS
      if (url.pathname === '/' || url.pathname === '/index.html') {
        const indexRequest = new Request(new URL('/index.html', request.url).toString(), {
          method: request.method,
          headers: request.headers,
        });
        return env.ASSETS.fetch(indexRequest);
      }
      return env.ASSETS.fetch(request);
    }

    // ─── Health check ──────────────────────────────────────────
    if (path === 'health') {
      return jsonResponse({ status: 'ok', edge: true }, 200, request);
    }

    // ─── JWXT direct proxy test ──────────────────────────────
    if (path === 'jwxt-test') {
      const sessionId = request.headers.get('X-Session-Id');
      if (!sessionId) return errorResponse('Missing X-Session-Id', 400, request);
      const session = await getLocalSession(request, env);
      if (!session || !session.cookies) return errorResponse('No session cookies found', 404, request);

      const jwxtUrl = 'https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html';
      try {
        const start = Date.now();
        const jwxtRes = await fetch(jwxtUrl, {
          headers: {
            'Cookie': session.cookies,
            'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          },
          signal: AbortSignal.timeout(15000),
        });
        const elapsed = Date.now() - start;
        const body = await jwxtRes.text();
        // Check auth status more precisely
        const hasMenuData = body.includes('initMenu') || body.includes('cdbh');
        const hasStudentInfo = /col_xm|学生信息|个人信息/.test(body);
        const isRedirect = body.length < 1000 && (body.includes('login') || body.includes('cas'));
        const isLoginPage = body.includes('lyuapServer') && body.includes('password');
        return jsonResponse({
          jwxtHttpStatus: jwxtRes.status,
          elapsedMs: elapsed,
          bodyLen: body.length,
          hasMenuData,
          hasStudentInfo,
          isRedirect,
          isLoginPage,
          snippet: body.slice(0, 300).replace(/\s+/g, ' '),
        }, 200, request);
      } catch (e) {
        return jsonResponse({ error: e.message }, 502, request);
      }
    }

    // ─── KV diagnostic ────────────────────────────────────────
    if (path === 'kv-test') {
      const hasKV = !!(env && env.SESSIONS_KV);
      let kvWrite = 'not attempted';
      let kvRead = 'not attempted';
      let sessionWrite = 'not attempted';
      let sessionRead = 'not attempted';
      if (hasKV) {
        try {
          await env.SESSIONS_KV.put('diag:test', 'ok', { expirationTtl: 60 });
          kvWrite = 'success';
          const val = await env.SESSIONS_KV.get('diag:test');
          kvRead = val === 'ok' ? 'success' : 'mismatch: ' + JSON.stringify(val);
        } catch (e) {
          kvWrite = 'error: ' + e.message;
        }
        // Simulate a real session write with larger payload and longer TTL
        try {
          const fakeSession = {
            cookies: 'route=' + 'x'.repeat(200) + '; JSESSIONID=' + 'y'.repeat(100) + '; BIGipServerpool_jwxt=' + 'z'.repeat(150),
            ehallCookies: 'sid=' + 'e'.repeat(50),
            studentName: '测试学生',
          };
          const fakeKey = 'session:test-' + Date.now();
          await env.SESSIONS_KV.put(fakeKey, JSON.stringify(fakeSession), { expirationTtl: 7200 });
          const verifyVal = await env.SESSIONS_KV.get(fakeKey);
          if (verifyVal) {
            sessionWrite = 'success (' + JSON.stringify(fakeSession).length + ' bytes)';
            sessionRead = 'success';
            // Clean up
            await env.SESSIONS_KV.delete(fakeKey);
          } else {
            sessionWrite = 'success but read-back empty';
            sessionRead = 'empty';
          }
        } catch (e) {
          sessionWrite = 'error: ' + e.message;
        }
      }
      return jsonResponse({
        hasKV,
        kvWrite,
        kvRead,
        sessionWrite,
        sessionRead,
        localSessionCount: localSessions.size,
      }, 200, request);
    }

    // ─── Auto-login (edge) ─────────────────────────────────────
    if (path === 'auth/auto-login' && request.method === 'POST') {
      try {
        const body = await request.json();
        let { account, password, encryptedPassword, keyId } = body;

        // If password is RSA-encrypted, call Vercel's fast decrypt endpoint
        // instead of proxying the entire auto-login (CAS login is too slow).
        if (encryptedPassword && keyId) {
          console.log(`[auto-login] Decrypting password: keyId=${keyId}, encryptedPassword length=${encryptedPassword.length}`);
          password = await decryptPasswordOnVercel(encryptedPassword, keyId, env);
          if (!password) {
            console.error(`[auto-login] Password decryption failed for account=${account}, keyId=${keyId}`);
            return errorResponse('密码解密失败，请重试', 400, request);
          }
          console.log(`[auto-login] Password decrypted successfully for account=${account}`);
        }

        if (!account || !password) {
          return errorResponse('账号和密码不能为空', 400, request);
        }

        const result = await casAutoLogin(account, password, env);

        if (result.error) {
          return errorResponse(result.error, 401, request);
        }

        // Create a session on Vercel backend.
        // This is NOT best-effort — if it fails, the frontend will get
        // a sessionId that doesn't exist in the DB, causing immediate
        // 401 "会话已过期" on subsequent API calls.
        let vercelResult = await createSessionOnBackend(result, account, password, env);
        if (!vercelResult.sessionId) {
          // Retry once after a short delay (Vercel cold-start / Neon wake-up)
          await sleep(2000);
          vercelResult = await createSessionOnBackend(result, account, password, env);
        }
        if (!vercelResult.sessionId) {
          console.error(`createSessionOnBackend failed twice after auto-login: ${vercelResult.error}`);
          return errorResponse(`会话创建失败: ${vercelResult.error || '未知错误'}`, 503, request);
        }

        // Store local session mapping so proxied requests can inject cookies.
        // JWXT cookies are IP-bounded to this Worker's edge location, so
        // Vercel (different IP) cannot validate them — we must inject them
        // on every proxied request.
        const sessionId = vercelResult.sessionId;
        const sessionData = {
          cookies: result.cookies,
          ehallCookies: result.ehallCookies,
          studentName: result.studentName,
        };
        localSessions.set(sessionId, sessionData);
        const kvResult = await saveSessionToKV(sessionId, sessionData, env);

        return jsonResponse({
          status: 'ok',
          sessionId,
          studentName: result.studentName,
          studentId: null,
          credentialToken: result.credentialToken,
          ehallCookies: result.ehallCookies,
          ehallAuthToken: null,
          _kv: kvResult,
        }, 200, request);
      } catch (e) {
        return errorResponse(`登录失败: ${e.message}`, 500, request);
      }
    }

    // ─── Relogin (edge) ────────────────────────────────────────
    if (path === 'auth/relogin' && request.method === 'POST') {
      try {
        const body = await request.json();
        const { credentialToken } = body;
        if (!credentialToken) {
          return errorResponse('凭据不能为空', 400, request);
        }

        const key = env.CREDENTIAL_ENCRYPTION_KEY || '';
        if (!key) {
          return errorResponse('服务器配置错误', 500, request);
        }

        // Decrypt credentials using AES-GCM (same algorithm as encryptCredentials)
        let credentials;
        try {
          credentials = await decryptCredentials(credentialToken, key);
        } catch (e) {
          return errorResponse('凭据已失效，请重新登录', 401, request);
        }

        // Perform CAS auto-login with decrypted credentials
        const result = await casAutoLogin(credentials.account, credentials.password, env);

        if (result.error) {
          return errorResponse(result.error, 401, request);
        }

        // Always keep a local session (cookies are IP-bounded to this Worker).
        // Create session on Vercel backend — retry once on failure.
        let vercelResult = await createSessionOnBackend(result, credentials.account, credentials.password, env);
        if (!vercelResult.sessionId) {
          await sleep(2000);
          vercelResult = await createSessionOnBackend(result, credentials.account, credentials.password, env);
        }
        if (!vercelResult.sessionId) {
          console.error(`createSessionOnBackend failed twice after relogin: ${vercelResult.error}`);
          return errorResponse(`会话创建失败: ${vercelResult.error || '未知错误'}`, 503, request);
        }

        const sessionId = vercelResult.sessionId;
        const sessionData = {
          cookies: result.cookies,
          ehallCookies: result.ehallCookies,
          studentName: result.studentName,
        };
        localSessions.set(sessionId, sessionData);
        const kvResult = await saveSessionToKV(sessionId, sessionData, env);

        return jsonResponse({
          status: 'ok',
          sessionId,
          studentName: result.studentName,
          studentId: null,
          credentialToken: result.credentialToken || credentialToken,
          ehallCookies: result.ehallCookies,
          ehallAuthToken: null,
          _kv: kvResult,
        }, 200, request);
      } catch (e) {
        return errorResponse(`重新登录失败: ${e.message}`, 500, request);
      }
    }

    // ─── All other routes: proxy to Vercel ─────────────────────
    // Inject local session cookies if available (bypass Vercel's IP-bounded cookie issue).
    // Check memory first, then Cloudflare KV for cross-instance persistence.
    const sessionId = request.headers.get('X-Session-Id');
    const localSession = await getLocalSession(request, env);
    let hadLocalSession = !!localSession;
    if (localSession) {
      request = injectSessionCookies(request, localSession);
    } else if (sessionId) {
      console.warn(`[proxy] No localSession found for sessionId=${sessionId.slice(0,8)}... — cookies will NOT be injected`);
    }
    return proxyToVercel(request, env, url, hadLocalSession);
  },
};

// ─── Decrypt password via Vercel (fast, < 1s) ──────────────────────
async function decryptPasswordOnVercel(encryptedPassword, keyId, env) {
  const vercelOrigin = (env.API_ORIGIN || 'https://api-one-zeta-dc0jrazxzq.vercel.app').replace(/\/$/, '');

  try {
    const res = await fetch(`${vercelOrigin}/internal/decrypt-password`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Internal-Key': env.INTERNAL_API_KEY || '',
      },
      body: JSON.stringify({ encrypted_password: encryptedPassword, key_id: keyId }),
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) {
      const data = await res.json();
      return data.password;
    }
    const errorBody = await res.text().catch(() => '');
    console.error(`decryptPasswordOnVercel failed: status=${res.status} body=${errorBody.slice(0, 300)}`);
  } catch (e) {
    console.error(`decryptPasswordOnVercel error: ${e.message}`);
  }
  return null;
}

// ─── Create session on Vercel backend ──────────────────────────────
// Returns { sessionId: string } on success, or { error: string, status: number } on failure.
async function createSessionOnBackend(loginResult, account, password, env) {
  const vercelOrigin = (env.API_ORIGIN || 'https://api-one-zeta-dc0jrazxzq.vercel.app').replace(/\/$/, '');

  try {
    const res = await fetch(`${vercelOrigin}/internal/create-session`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Internal-Key': env.INTERNAL_API_KEY || '',
      },
      body: JSON.stringify({
        account,
        cookies: loginResult.cookies,
        password: password || null,
        ehall_cookies: loginResult.ehallCookies,
        student_name: loginResult.studentName,
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (res.ok) {
      const data = await res.json();
      return { sessionId: data.sessionId, credentialToken: data.credentialToken || null };
    }
    // Log non-OK response for debugging
    const errorText = await res.text().catch(() => '');
    console.error(`createSessionOnBackend failed: status=${res.status} body=${errorText}`);
    return { error: `后端返回 ${res.status}: ${errorText.slice(0, 200)}`, status: res.status };
  } catch (e) {
    console.error(`createSessionOnBackend error: ${e.message}`);
    return { error: `网络错误: ${e.message}`, status: 0 };
  }
}

// ─── Proxy to Vercel ───────────────────────────────────────────────
async function proxyToVercel(request, env, url, hadLocalSession = true) {
  const origin = (env.API_ORIGIN || 'https://api-one-zeta-dc0jrazxzq.vercel.app').replace(/\/$/, '');
  // Strip /api/ prefix for Vercel backend compatibility
  let upstreamPath = url.pathname;
  if (upstreamPath.startsWith('/api/')) {
    upstreamPath = upstreamPath.slice(4); // Remove /api
  }
  const upstreamUrl = new URL(upstreamPath + url.search, origin);

  // Save the original request body so we can re-create it for each retry.
  // request.body is a ReadableStream that can only be consumed once.
  let savedBody = null;
  try {
    if (request.body) {
      savedBody = await request.clone().text();
    }
  } catch {}

  // Retry on 5xx from Vercel (up to 2 retries with exponential backoff)
  const maxRetries = 2;
  let lastError = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      // Re-create the upstream request for each attempt — body streams
      // can only be consumed once, so we MUST rebuild the request.
      let upstreamRequest;
      if (savedBody !== null) {
        upstreamRequest = new Request(upstreamUrl, {
          method: request.method,
          headers: request.headers,
          body: savedBody,
        });
      } else {
        upstreamRequest = new Request(upstreamUrl, request);
      }

      const response = await fetch(upstreamRequest, {
        signal: AbortSignal.timeout(12000),
      });
      // If it's not a 5xx, return immediately
      if (response.status < 500) {
        const headers = new Headers(response.headers);
        for (const [key, value] of Object.entries(corsHeaders(request))) {
          headers.set(key, value);
        }
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers,
        });
      }
      // 5xx — retry after backoff
      lastError = new Error(`Vercel returned ${response.status}`);
      if (attempt < maxRetries) {
        await sleep(Math.min(200 * Math.pow(2, attempt), 2000));
      }
    } catch (e) {
      lastError = e;
      if (attempt < maxRetries) {
        await sleep(Math.min(200 * Math.pow(2, attempt), 2000));
      }
    }
  }

  // All retries exhausted — return a friendly error.
  // If the Worker had no local session cookies to inject, the downstream
  // failures are almost certainly due to stale DB-stored cookies.
  // Return 401 so the frontend triggers a relogin immediately.
  const status = hadLocalSession ? 502 : 401;
  const errorBody = JSON.stringify({
    detail: hadLocalSession
      ? '后端服务暂时不可用，请稍后重试'
      : '会话已过期，请重新登录',
  });
  console.error(`proxyToVercel failed after ${maxRetries + 1} attempts (hadLocalSession=${hadLocalSession}): ${lastError?.message}`);
  return new Response(errorBody, {
    status,
    statusText: status === 401 ? 'Unauthorized' : 'Bad Gateway',
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders(request),
    },
  });
}
// trigger redeploy 2026-06-11T01:45:00+08:00
