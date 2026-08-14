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
// jwxt.seig.edu.cn currently serves a certificate that does not match the
// hostname on some networks. jwxt.gzus.edu.cn points at the same JWXT service
// with a valid certificate, so use it for Worker-side JWXT fetches.
const JWXT_ORIGIN = 'https://jwxt.gzus.edu.cn';
const JWXT_LEGACY_ORIGIN = 'https://jwxt.seig.edu.cn';
const JWXT_SERVICE_URL = `${JWXT_ORIGIN}/sso/lyiotlogin`;
const JWXT_LEGACY_SERVICE_URL = `${JWXT_LEGACY_ORIGIN}/sso/lyiotlogin`;
// Use the certificate-valid JWXT host for the initial CAS service ticket.
// The legacy host may set cookies that look present but still land on the
// JWXT login page when JSON endpoints are requested.
const SERVICE_URL = JWXT_SERVICE_URL;
const JWXT_SERVICE_URLS = [JWXT_SERVICE_URL, JWXT_LEGACY_SERVICE_URL];
const EHALL_URL = 'https://ehall.gzus.edu.cn';
const EHALL_CAS_SERVICE_URL = 'http://ehall.gzus.edu.cn/shiro-cas';
const JWXT_BASE = `${JWXT_ORIGIN}/jwglxt`;
const JWXT_REFERER = `${JWXT_BASE}/xtgl/index_initMenu.html`;
const CANONICAL_APP_ORIGIN = 'https://onegzus.cc.cd';
const STATIC_ASSET_PATH_RE = /(?:^\/(?:assets|canvaskit|icons)\/|^\/(?:flutter_bootstrap|flutter|main\.dart|gzus_pwa|gzus_pwa_sw)\.js$|^\/manifest\.json$|^\/version\.json$|^\/favicon\.png$|\.(?:js|mjs|wasm|json|otf|ttf|woff2?|png|jpg|jpeg|webp|gif|svg|ico|css|map)$)/i;
const DASHBOARD_DIRECT_TIMEOUT_MS = 9000;
const DASHBOARD_BACKEND_TIMEOUT_MS = 12000;
const DASHBOARD_MODULE_TIMEOUT_MS = 13000;
const DASHBOARD_TOTAL_TIMEOUT_MS = 20000;

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
    return this.getCookiesForHost(host);
  }

  getCookiesForHost(host) {
    const parts = [];
    const seenNames = new Set();
    const hostLower = host.toLowerCase();
    for (const [domain, nameMap] of this.cookies) {
      const domainLower = domain.toLowerCase();
      if (hostLower === domainLower || hostLower.endsWith('.' + domainLower)) {
        for (const [name, value] of nameMap) {
          if (seenNames.has(name)) continue;
          seenNames.add(name);
          parts.push(`${name}=${value}`);
        }
      }
    }
    return parts.join('; ');
  }

  getEhallCookies() {
    const parts = [];
    for (const [domain, nameMap] of this.cookies) {
      if (domain.includes('ehall')) {
        for (const [name, value] of nameMap) {
          parts.push(`${name}=${value}`);
        }
      }
    }
    return parts.join('; ');
  }

  getEhallAuthToken() {
    for (const [domain, nameMap] of this.cookies) {
      if (domain.includes('ehall') && nameMap.has('Authorization')) {
        return nameMap.get('Authorization');
      }
    }
    return null;
  }
}

function getJwxtCookies(jar, preferredServiceUrl = JWXT_SERVICE_URL) {
  const hosts = [
    preferredServiceUrl,
    JWXT_SERVICE_URL,
    JWXT_LEGACY_SERVICE_URL,
  ].map((serviceUrl) => {
    try {
      return new URL(serviceUrl).hostname;
    } catch {
      return '';
    }
  }).filter(Boolean);

  for (const host of [...new Set(hosts)]) {
    const cookies = jar.getCookiesForHost(host);
    if (cookies) return cookies;
  }
  return '';
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
  const ehallSession = ehallResult.status === 'fulfilled' ? ehallResult.value : null;

  if (!jwxtCookies) {
    const reason = jwxtResult.status === 'rejected'
      ? (jwxtResult.reason && jwxtResult.reason.message ? jwxtResult.reason.message : String(jwxtResult.reason))
      : '未获取到教务系统会话 Cookie';
    console.warn(`[auto-login] JWXT session unavailable: ${reason}`);
    return {
      error: `教务系统登录失败：${reason}`,
      ehallCookies: ehallSession && ehallSession.cookies ? ehallSession.cookies : null,
      ehallAuthToken: ehallSession && ehallSession.authToken ? ehallSession.authToken : null,
    };
  }

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
    ehallCookies: ehallSession && ehallSession.cookies ? ehallSession.cookies : null,
    ehallAuthToken: ehallSession && ehallSession.authToken ? ehallSession.authToken : null,
    studentName,
    credentialToken,
  };
}

async function fetchJwxtCookies(ticket, tgt, jar, timeout) {
  const diagnostics = [];

  function looksLikeJwxtLoginPage(text) {
    return text.includes('login_slogin') ||
      /<input[^>]*type\s*=\s*['"]password['"]/i.test(text) ||
      text.includes('lyuapServer/login');
  }

  async function verifyJwxtCookies(serviceUrl, cookies, source) {
    if (!cookies) return '';
    try {
      const origin = new URL(serviceUrl).origin;
      const [res, html] = await fetchGbkText(`${origin}/jwglxt/xsxxxggl/xsgrxxwh_cxXsgrxx.html`, {
        headers: {
          'Cookie': cookies,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          'Referer': `${origin}/jwglxt/xtgl/index_initMenu.html`,
        },
        signal: AbortSignal.timeout(Math.min(timeout, 10000)),
      });
      const ok = Boolean(res && res.ok && html && !looksLikeJwxtLoginPage(html));
      diagnostics.push(`${source}:${new URL(serviceUrl).hostname}:verify=${ok ? 'ok' : 'login-page'}:status=${res ? res.status : 'null'}`);
      return ok ? cookies : '';
    } catch (e) {
      diagnostics.push(`${source}:${new URL(serviceUrl).hostname}:verify-error=${e && e.message ? e.message : String(e)}`);
      return '';
    }
  }

  async function followServiceTicket(serviceUrl, serviceTicket, source) {
    if (!serviceUrl || !serviceTicket) return '';
    const redirectUrl = serviceTicketUrl(serviceUrl, serviceTicket);
    try {
      const res = await fetchWithCookies(redirectUrl, {
        signal: AbortSignal.timeout(timeout),
      }, jar);
      const cookies = getJwxtCookies(jar, serviceUrl);
      const contentType = res.headers.get('Content-Type') || '';
      diagnostics.push(`${source}:${new URL(serviceUrl).hostname}:status=${res.status}:cookies=${cookies ? cookies.length : 0}:type=${contentType}`);
      return verifyJwxtCookies(serviceUrl, cookies, source);
    } catch (e) {
      diagnostics.push(`${source}:${new URL(serviceUrl).hostname}:error=${e && e.message ? e.message : String(e)}`);
      return '';
    }
  }

  async function requestServiceTicket(serviceUrl) {
    if (!tgt || !serviceUrl) return '';
    try {
      const stRes = await fetchWithCookies(
        `${CAS_BASE}/lyuapServer/v1/tickets/${tgt}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ service: serviceUrl }),
          signal: AbortSignal.timeout(timeout),
        },
        jar
      );
      if (!stRes.ok) {
        diagnostics.push(`st:${new URL(serviceUrl).hostname}:status=${stRes.status}`);
        return '';
      }
      const serviceTicket = (await stRes.text()).trim();
      diagnostics.push(`st:${new URL(serviceUrl).hostname}:ok=${serviceTicket ? 'yes' : 'empty'}`);
      return serviceTicket;
    } catch (e) {
      diagnostics.push(`st:${new URL(serviceUrl).hostname}:error=${e && e.message ? e.message : String(e)}`);
      return '';
    }
  }

  async function freshCookies(serviceUrl, source = 'fresh') {
    const freshTicket = await requestServiceTicket(serviceUrl);
    return followServiceTicket(serviceUrl, freshTicket, source);
  }

  async function delayedFreshCookies(serviceUrl, delayMs) {
    await sleep(delayMs);
    return freshCookies(serviceUrl, 'fresh-retry');
  }

  async function firstNonEmpty(attempts) {
    const pending = attempts.map((promise) => {
      let wrapped;
      wrapped = promise.catch(() => '').then((cookies) => ({ wrapped, cookies }));
      return wrapped;
    });
    while (pending.length > 0) {
      const { wrapped, cookies } = await Promise.race(pending);
      if (cookies) return cookies;
      const index = pending.indexOf(wrapped);
      if (index >= 0) pending.splice(index, 1);
    }
    return '';
  }

  // Prefer the certificate-valid JWXT host. Legacy/initial tickets may produce
  // cookies that are accepted by CAS but later return HTML for JSON endpoints.
  const canonicalCookies = await firstNonEmpty([
    freshCookies(JWXT_SERVICE_URL),
    delayedFreshCookies(JWXT_SERVICE_URL, 1200),
  ]);
  if (canonicalCookies) return canonicalCookies;

  for (const serviceUrl of JWXT_SERVICE_URLS) {
    if (serviceUrl === JWXT_SERVICE_URL) continue;
    const cookies = await freshCookies(serviceUrl);
    if (cookies) return cookies;
  }

  const initialCookies = await followServiceTicket(SERVICE_URL, ticket, 'initial');
  if (initialCookies) return initialCookies;

  const jarCookies = getJwxtCookies(jar);
  if (jarCookies) {
    const verified = await verifyJwxtCookies(JWXT_SERVICE_URL, jarCookies, 'jar');
    if (verified) return verified;
  }

  throw new Error(`未获取到教务系统会话 Cookie（${diagnostics.join('; ') || 'no diagnostics'}）`);
}

function serviceTicketUrl(serviceUrl, ticket) {
  if (serviceUrl.includes('?')) {
    return `${serviceUrl}&ticket=${encodeURIComponent(ticket)}`;
  }
  return `${serviceUrl}?ticket=${encodeURIComponent(ticket)}`;
}

async function fetchEhallSession(tgt, jar, timeout) {
  if (!tgt) return null;
  const ehallServiceUrl = EHALL_CAS_SERVICE_URL;
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
        const cookies = jar.getEhallCookies();
        if (cookies) {
          return {
            cookies,
            authToken: jar.getEhallAuthToken(),
          };
        }
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
  const origin = vercelOrigin(env);

  try {
    const b64 = uint8ArrayToBase64(imageBytes);
    const res = await fetch(`${origin}/internal/ocr`, {
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
const CREDENTIAL_TOKEN_VERSION = 1;
const CREDENTIAL_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
const CREDENTIAL_TOKEN_CLOCK_SKEW_MS = 5 * 60 * 1000;

async function encryptCredentials(account, password, key) {
  const encoder = new TextEncoder();
  const keyData = await crypto.subtle.digest('SHA-256', encoder.encode(key));
  const cryptoKey = await crypto.subtle.importKey(
    'raw', keyData, { name: 'AES-GCM' }, false, ['encrypt']
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = JSON.stringify({
    version: CREDENTIAL_TOKEN_VERSION,
    issuedAt: Date.now(),
    account,
    password,
  });
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

async function decryptCredentials(token, key, now) {
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
  const credentials = JSON.parse(plaintext);
  if (
    credentials.version !== CREDENTIAL_TOKEN_VERSION ||
    !Number.isSafeInteger(credentials.issuedAt) ||
    typeof credentials.account !== 'string' ||
    credentials.account.length === 0 ||
    typeof credentials.password !== 'string' ||
    credentials.password.length === 0
  ) {
    throw new Error('Invalid credential format');
  }
  const age = now - credentials.issuedAt;
  if (age < -CREDENTIAL_TOKEN_CLOCK_SKEW_MS || age > CREDENTIAL_TOKEN_TTL_MS) {
    throw new Error('Credential token expired');
  }
  return {
    account: credentials.account,
    password: credentials.password,
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

// Vercel 后端源地址：去掉尾部斜杠，供代理与内部桥接统一使用
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

function md5(input) {
  function add32(a, b) {
    return (a + b) & 0xffffffff;
  }
  function cmn(q, a, b, x, s, t) {
    a = add32(add32(a, q), add32(x, t));
    return add32((a << s) | (a >>> (32 - s)), b);
  }
  function ff(a, b, c, d, x, s, t) {
    return cmn((b & c) | ((~b) & d), a, b, x, s, t);
  }
  function gg(a, b, c, d, x, s, t) {
    return cmn((b & d) | (c & (~d)), a, b, x, s, t);
  }
  function hh(a, b, c, d, x, s, t) {
    return cmn(b ^ c ^ d, a, b, x, s, t);
  }
  function ii(a, b, c, d, x, s, t) {
    return cmn(c ^ (b | (~d)), a, b, x, s, t);
  }
  function md5cycle(x, k) {
    let [a, b, c, d] = x;
    a = ff(a, b, c, d, k[0], 7, -680876936);
    d = ff(d, a, b, c, k[1], 12, -389564586);
    c = ff(c, d, a, b, k[2], 17, 606105819);
    b = ff(b, c, d, a, k[3], 22, -1044525330);
    a = ff(a, b, c, d, k[4], 7, -176418897);
    d = ff(d, a, b, c, k[5], 12, 1200080426);
    c = ff(c, d, a, b, k[6], 17, -1473231341);
    b = ff(b, c, d, a, k[7], 22, -45705983);
    a = ff(a, b, c, d, k[8], 7, 1770035416);
    d = ff(d, a, b, c, k[9], 12, -1958414417);
    c = ff(c, d, a, b, k[10], 17, -42063);
    b = ff(b, c, d, a, k[11], 22, -1990404162);
    a = ff(a, b, c, d, k[12], 7, 1804603682);
    d = ff(d, a, b, c, k[13], 12, -40341101);
    c = ff(c, d, a, b, k[14], 17, -1502002290);
    b = ff(b, c, d, a, k[15], 22, 1236535329);
    a = gg(a, b, c, d, k[1], 5, -165796510);
    d = gg(d, a, b, c, k[6], 9, -1069501632);
    c = gg(c, d, a, b, k[11], 14, 643717713);
    b = gg(b, c, d, a, k[0], 20, -373897302);
    a = gg(a, b, c, d, k[5], 5, -701558691);
    d = gg(d, a, b, c, k[10], 9, 38016083);
    c = gg(c, d, a, b, k[15], 14, -660478335);
    b = gg(b, c, d, a, k[4], 20, -405537848);
    a = gg(a, b, c, d, k[9], 5, 568446438);
    d = gg(d, a, b, c, k[14], 9, -1019803690);
    c = gg(c, d, a, b, k[3], 14, -187363961);
    b = gg(b, c, d, a, k[8], 20, 1163531501);
    a = gg(a, b, c, d, k[13], 5, -1444681467);
    d = gg(d, a, b, c, k[2], 9, -51403784);
    c = gg(c, d, a, b, k[7], 14, 1735328473);
    b = gg(b, c, d, a, k[12], 20, -1926607734);
    a = hh(a, b, c, d, k[5], 4, -378558);
    d = hh(d, a, b, c, k[8], 11, -2022574463);
    c = hh(c, d, a, b, k[11], 16, 1839030562);
    b = hh(b, c, d, a, k[14], 23, -35309556);
    a = hh(a, b, c, d, k[1], 4, -1530992060);
    d = hh(d, a, b, c, k[4], 11, 1272893353);
    c = hh(c, d, a, b, k[7], 16, -155497632);
    b = hh(b, c, d, a, k[10], 23, -1094730640);
    a = hh(a, b, c, d, k[13], 4, 681279174);
    d = hh(d, a, b, c, k[0], 11, -358537222);
    c = hh(c, d, a, b, k[3], 16, -722521979);
    b = hh(b, c, d, a, k[6], 23, 76029189);
    a = hh(a, b, c, d, k[9], 4, -640364487);
    d = hh(d, a, b, c, k[12], 11, -421815835);
    c = hh(c, d, a, b, k[15], 16, 530742520);
    b = hh(b, c, d, a, k[2], 23, -995338651);
    a = ii(a, b, c, d, k[0], 6, -198630844);
    d = ii(d, a, b, c, k[7], 10, 1126891415);
    c = ii(c, d, a, b, k[14], 15, -1416354905);
    b = ii(b, c, d, a, k[5], 21, -57434055);
    a = ii(a, b, c, d, k[12], 6, 1700485571);
    d = ii(d, a, b, c, k[3], 10, -1894986606);
    c = ii(c, d, a, b, k[10], 15, -1051523);
    b = ii(b, c, d, a, k[1], 21, -2054922799);
    a = ii(a, b, c, d, k[8], 6, 1873313359);
    d = ii(d, a, b, c, k[15], 10, -30611744);
    c = ii(c, d, a, b, k[6], 15, -1560198380);
    b = ii(b, c, d, a, k[13], 21, 1309151649);
    a = ii(a, b, c, d, k[4], 6, -145523070);
    d = ii(d, a, b, c, k[11], 10, -1120210379);
    c = ii(c, d, a, b, k[2], 15, 718787259);
    b = ii(b, c, d, a, k[9], 21, -343485551);
    x[0] = add32(a, x[0]);
    x[1] = add32(b, x[1]);
    x[2] = add32(c, x[2]);
    x[3] = add32(d, x[3]);
  }
  function md5blk(s) {
    const blocks = [];
    for (let i = 0; i < 64; i += 4) {
      blocks[i >> 2] = s.charCodeAt(i) + (s.charCodeAt(i + 1) << 8) +
        (s.charCodeAt(i + 2) << 16) + (s.charCodeAt(i + 3) << 24);
    }
    return blocks;
  }
  function md51(s) {
    let n = s.length;
    const state = [1732584193, -271733879, -1732584194, 271733878];
    let i;
    for (i = 64; i <= n; i += 64) {
      md5cycle(state, md5blk(s.substring(i - 64, i)));
    }
    s = s.substring(i - 64);
    const tail = Array(16).fill(0);
    for (i = 0; i < s.length; i++) {
      tail[i >> 2] |= s.charCodeAt(i) << ((i % 4) << 3);
    }
    tail[i >> 2] |= 0x80 << ((i % 4) << 3);
    if (i > 55) {
      md5cycle(state, tail);
      tail.fill(0);
    }
    tail[14] = n * 8;
    md5cycle(state, tail);
    return state;
  }
  function rhex(n) {
    let s = '';
    for (let j = 0; j < 4; j++) {
      s += ((n >> (j * 8 + 4)) & 0x0f).toString(16) +
        ((n >> (j * 8)) & 0x0f).toString(16);
    }
    return s;
  }
  return md51(unescape(encodeURIComponent(input))).map(rhex).join('');
}

// ─── CORS Headers ──────────────────────────────────────────────────
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

// ─── Session store (memory + Cloudflare KV fallback) ─────────────
// Memory is fast but per-instance.  KV provides cross-instance
// persistence so a Worker cold-start or different colo can still
// inject JWXT cookies (which are IP-bounded to the Worker edge).
const SESSION_KV_TTL = 7200; // 2 hours, matches Vercel session TTL
const localSessions = new Map(); // sessionId -> { cookies, ehallCookies, studentName }
const localAccountSessions = new Map(); // account hash -> current sessionId
// 会话「当前账号有效性」验证结果的内存缓存窗口：窗口内跳过 KV index 读取，
// 避免每个带 session 的请求都产生一次 KV 读（跨实例踢下线感知最坏延迟一个窗口）。
const SESSION_VALIDATION_CACHE_MS = 60 * 1000;
const localSessionValidatedAt = new Map(); // sessionId -> last validated timestamp
const ACADEMIC_CACHE_TTL = 1800; // 30 minutes, enough to absorb JWXT bursts
const localAcademicCache = new Map(); // key -> { data, cachedAt }
const localAcademicInFlight = new Map(); // key -> Promise<{ jwxtRes, data }>

function generateSessionId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

async function accountSessionIndexKey(account) {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(account)
  );
  const accountHash = Array.from(
    new Uint8Array(digest),
    byte => byte.toString(16).padStart(2, '0')
  ).join('');
  return `account-session:${accountHash}`;
}

function createEdgeSessionData(account, loginResult, expiresAt) {
  return {
    account,
    cookies: loginResult.cookies,
    ehallCookies: loginResult.ehallCookies,
    ehallAuthToken: loginResult.ehallAuthToken,
    studentName: loginResult.studentName,
    expiresAt,
  };
}

function requireSessionsKV(env) {
  if (!env || !env.SESSIONS_KV) {
    throw new Error('Cloudflare KV 绑定 SESSIONS_KV 不可用');
  }
  return env.SESSIONS_KV;
}

// 按会话 ID 查找 JWXT cookies：内存优先，KV 兜底并写回内存缓存。
// 供 JWXT 代理、_proxy、getLocalSession 复用，避免三处重复查找逻辑。
async function lookupSessionCookies(sessionId, env) {
  const localData = localSessions.get(sessionId);
  if (localData && localData.cookies) return localData.cookies;
  try {
    if (env && env.SESSIONS_KV) {
      const raw = await env.SESSIONS_KV.get(`session:${sessionId}`);
      if (raw) {
        const data = JSON.parse(raw);
        localSessions.set(sessionId, data); // cache for subsequent requests
        return data.cookies;
      }
    }
  } catch (e) {
    console.warn(`[kv] 查找会话 cookies 失败 ${sessionId.slice(0, 8)}: ${e.message}`);
  }
  return null;
}

async function createPersistentSession(loginResult, account, env) {
  requireSessionsKV(env);
  let backendResult = null;
  for (let attempt = 1; attempt <= 2; attempt++) {
    backendResult = await createSessionOnBackend(loginResult, account, env);
    if (backendResult.sessionId) break;
    console.warn('[session] 后端会话创建失败', {
      attempt,
      maxAttempts: 2,
      status: backendResult.status,
      error: backendResult.error,
    });
    if (attempt < 2) await sleep(2000);
  }
  if (!backendResult || !backendResult.sessionId) {
    throw new Error(backendResult && backendResult.error
      ? backendResult.error
      : '后端未返回会话标识');
  }

  const sessionData = createEdgeSessionData(
    account,
    loginResult,
    Date.now() + SESSION_KV_TTL * 1000
  );
  await saveSessionToKV(backendResult.sessionId, sessionData, env);
  return { sessionId: backendResult.sessionId, isAdmin: backendResult.isAdmin === true };
}

async function validateCurrentAccountSession(sessionId, data, env, now) {
  if (
    !data ||
    typeof data !== 'object' ||
    typeof data.account !== 'string' ||
    data.account.length === 0 ||
    typeof data.cookies !== 'string' ||
    data.cookies.length === 0 ||
    !Number.isSafeInteger(data.expiresAt) ||
    now >= data.expiresAt
  ) {
    await deleteSessionFromStores(sessionId, data, env);
    return false;
  }
  // 验证窗口内直接信任内存结论，避免每请求一次 KV index 读
  const lastValidated = localSessionValidatedAt.get(sessionId) || 0;
  if (now - lastValidated < SESSION_VALIDATION_CACHE_MS) {
    return true;
  }
  const indexKey = await accountSessionIndexKey(data.account);
  let currentSessionId = localAccountSessions.get(indexKey) || null;
  if (env && env.SESSIONS_KV) {
    currentSessionId = await env.SESSIONS_KV.get(indexKey);
  }
  if (currentSessionId && currentSessionId !== sessionId) {
    localSessions.delete(sessionId);
    localSessionValidatedAt.delete(sessionId);
    return false;
  }
  localAccountSessions.set(indexKey, sessionId);
  localSessionValidatedAt.set(sessionId, now);
  return true;
}

async function saveSessionToKV(sessionId, data, env) {
  const sessionsKV = requireSessionsKV(env);
  const indexKey = data.account
    ? await accountSessionIndexKey(data.account)
    : null;
  const previousLocalSessionId = indexKey
    ? localAccountSessions.get(indexKey)
    : null;
  const key = `session:${sessionId}`;
  const cookiesLen = (data.cookies || '').length;
  const maxRetries = 2;
  let previousKvSessionId = null;
  let previousKvSessionResolved = false;
  let lastError = null;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      if (indexKey && !previousKvSessionResolved) {
        previousKvSessionId = await sessionsKV.get(indexKey);
        previousKvSessionResolved = true;
      }
      await sessionsKV.put(
        key,
        JSON.stringify(data),
        { expirationTtl: SESSION_KV_TTL }
      );
      if (indexKey) {
        await sessionsKV.put(
          indexKey,
          sessionId,
          { expirationTtl: SESSION_KV_TTL }
        );
      }
      if (previousKvSessionId && previousKvSessionId !== sessionId) {
        await sessionsKV.delete(`session:${previousKvSessionId}`);
      }
      if (previousLocalSessionId && previousLocalSessionId !== sessionId) {
        localSessions.delete(previousLocalSessionId);
      }
      localSessions.set(sessionId, data);
      if (indexKey) localAccountSessions.set(indexKey, sessionId);
      console.log('[kv] 会话已持久化', {
        sessionId: sessionId.slice(0, 8),
        cookiesLength: cookiesLen,
      });
      return;
    } catch (error) {
      lastError = error;
      console.warn('[kv] 会话持久化失败', {
        sessionId: sessionId.slice(0, 8),
        attempt,
        maxAttempts: maxRetries,
        error: error.message,
      });
      if (attempt < maxRetries) await sleep(200);
    }
  }
  throw new Error(
    `Cloudflare KV 会话写入失败：session=${sessionId.slice(0, 8)}, ` +
    `attempts=${maxRetries}, error=${lastError ? lastError.message : 'unknown'}`,
    { cause: lastError }
  );
}

async function deleteSessionFromStores(sessionId, data, env) {
  localSessions.delete(sessionId);
  localSessionValidatedAt.delete(sessionId);
  const indexKey = data && data.account
    ? await accountSessionIndexKey(data.account)
    : null;
  if (indexKey && localAccountSessions.get(indexKey) === sessionId) {
    localAccountSessions.delete(indexKey);
  }
  if (!env || !env.SESSIONS_KV) return;

  let lastError = null;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const currentSessionId = indexKey
        ? await env.SESSIONS_KV.get(indexKey)
        : null;
      await env.SESSIONS_KV.delete(`session:${sessionId}`);
      if (indexKey && currentSessionId === sessionId) {
        await env.SESSIONS_KV.delete(indexKey);
      }
      return;
    } catch (error) {
      lastError = error;
      console.warn(
        `[kv] Failed to delete session ${sessionId.slice(0, 8)} ` +
        `(attempt ${attempt}/2): ${error.message}`
      );
      if (attempt < 2) await sleep(200);
    }
  }
  throw lastError;
}

async function getLocalSession(request, env) {
  const sessionId = request.headers.get('X-Session-Id');
  if (!sessionId) return null;

  // 1. In-memory (same Worker instance that handled login)
  let data = localSessions.get(sessionId);
  if (data) {
    const isCurrent = await validateCurrentAccountSession(
      sessionId,
      data,
      env,
      Date.now()
    );
    return isCurrent ? data : null;
  }

  // 2. KV fallback (different Worker instance, cold-start, etc.)
  try {
    if (env && env.SESSIONS_KV) {
      const raw = await env.SESSIONS_KV.get(`session:${sessionId}`);
      if (raw) {
        data = JSON.parse(raw);
        if (!await validateCurrentAccountSession(
          sessionId,
          data,
          env,
          Date.now()
        )) {
          return null;
        }
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

function defaultAcademicPeriod() {
  const now = new Date();
  const month = now.getMonth() + 1;
  const year = month >= 9 ? now.getFullYear() : now.getFullYear() - 1;
  const term = month >= 9 || month <= 1 ? 1 : 2;
  return { year: String(year), term: String(term) };
}

function academicCacheKey(sessionId, path, year, term) {
  return `academic:${sessionId}:${path}:${year || ''}:${term || ''}`;
}

async function loadAcademicCache(env, key) {
  const local = localAcademicCache.get(key);
  if (local && Date.now() - local.cachedAt < ACADEMIC_CACHE_TTL * 1000) {
    return local;
  }
  try {
    if (env && env.SESSIONS_KV) {
      const raw = await env.SESSIONS_KV.get(key);
      if (raw) {
        const data = JSON.parse(raw);
        localAcademicCache.set(key, data);
        return data;
      }
    }
  } catch (e) {
    console.warn(`[academic-cache] load failed for ${key}: ${e.message}`);
  }
  return null;
}

async function saveAcademicCache(env, key, data) {
  const payload = { data, cachedAt: Date.now() };
  localAcademicCache.set(key, payload);
  try {
    if (env && env.SESSIONS_KV) {
      await env.SESSIONS_KV.put(key, JSON.stringify(payload), { expirationTtl: ACADEMIC_CACHE_TTL });
    }
  } catch (e) {
    console.warn(`[academic-cache] save failed for ${key}: ${e.message}`);
  }
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
  // Pass the student account so Vercel can store it for ecard/credits use
  if (session.account) {
    headers.set('X-Student-Account', session.account);
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

function buildVercelProxyHeaders(request) {
  const headers = new Headers(request.headers);
  const removeHeaders = [
    'Host',
    'Connection',
    'Keep-Alive',
    'Proxy-Authenticate',
    'Proxy-Authorization',
    'TE',
    'Trailer',
    'Transfer-Encoding',
    'Upgrade',
    'CF-Connecting-IP',
    'CF-IPCountry',
    'CF-Ray',
    'CF-Visitor',
    'CDN-Loop',
    'X-Forwarded-Host',
    'X-Forwarded-Proto',
    'X-Real-IP',
  ];
  for (const name of removeHeaders) {
    headers.delete(name);
  }

  const clientIp = request.headers.get('CF-Connecting-IP');
  if (clientIp && !headers.get('X-Forwarded-For')) {
    headers.set('X-Forwarded-For', clientIp);
  }
  headers.set('X-Forwarded-Proto', 'https');
  return headers;
}

// ─── Main Worker Handler ───────────────────────────────────────────
export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    // ─── CanvasKit assets ─────────────────────────────────────
    // CanvasKit JS and WASM must come from the same variant. Do not fall back
    // between /canvaskit and /canvaskit/chromium because Flutter's loader
    // decides the WASM URL before requesting the JS file; mixing variants can
    // crash startup with undefined CanvasKit symbols.
    if (
      url.pathname === '/canvaskit/canvaskit.js' ||
      url.pathname === '/canvaskit/canvaskit.wasm' ||
      url.pathname === '/canvaskit/chromium/canvaskit.js' ||
      url.pathname === '/canvaskit/chromium/canvaskit.wasm'
    ) {
      return serveStaticAsset(request, env);
    }
    if (url.pathname === '/canvaskit/chromium/main.dart.js') {
      return new Response('// CanvasKit chromium compat stub', {
        status: 200,
        headers: { 'Content-Type': 'application/javascript', ...corsHeaders(request) },
      });
    }

    // ─── JWXT proxy for Vercel backend ─────────────────────────
    // Vercel routes JWXT requests through the Worker to preserve the
    // Worker's edge IP (JWXT cookies are IP-bounded).
    const jwxtSessionId = request.headers.get('X-Jwxt-Session-Id');
    if (jwxtSessionId && (url.pathname.startsWith('/jwglxt/') || url.pathname.startsWith('/xtgl/'))) {
      const jwxtCookies = await lookupSessionCookies(jwxtSessionId, env);
      if (!jwxtCookies) {
        return new Response('JWXT session not found', { status: 502 });
      }
      const jwxtUrl = JWXT_ORIGIN + url.pathname + url.search;
      try {
        const jwxtRes = await fetch(jwxtUrl, {
          method: request.method,
          headers: {
            'Cookie': jwxtCookies,
            'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
            'Referer': JWXT_REFERER,
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
               url.pathname.startsWith('/ws') ||
               url.pathname.startsWith('/dashboard') ||
               url.pathname.startsWith('/exams') ||
               url.pathname.startsWith('/schedule') ||
               url.pathname.startsWith('/grades') ||
               url.pathname.startsWith('/credits') ||
               url.pathname.startsWith('/attendance') ||
               url.pathname.startsWith('/notices') ||
               url.pathname.startsWith('/_proxy')) {
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
        return fetchAsset(indexRequest, env);
      }
      return serveStaticAsset(request, env);
    }

    // ─── Health check ──────────────────────────────────────────
    if (path === 'health') {
      return jsonResponse({ status: 'ok', edge: true }, 200, request);
    }

    // ─── Worker HTTP proxy (for Vercel → JWXT/ecard) ─────────
    // Vercel sends selected school-system requests through Cloudflare so
    // remote services see the Worker's edge IP instead of Vercel's region.
    if (path === '_proxy' && request.method === 'POST') {
      try {
        const body = await request.json();
        const { url: targetUrl, method, headers: proxyHeaders, session_id } = body;
        if (!targetUrl) return errorResponse('Missing url', 400, request);

        // Two proxy modes:
        // 1. With session_id: JWXT proxy (injects cookies for IP-bounded JWXT access)
        // 2. Without session_id: ecard proxy (transparent forward to ecard API)
        let cookies = null;
        const parsedTarget = new URL(targetUrl);
        if (session_id) {
          cookies = await lookupSessionCookies(session_id, env);
          if (!cookies) {
            return new Response('JWXT session cookies not found', { status: 502 });
          }
        } else if (
          parsedTarget.protocol !== 'https:' ||
          parsedTarget.hostname !== 'ecarduser.gzus.edu.cn'
        ) {
          return errorResponse('Unsupported proxy target', 403, request);
        }

        // Forward the request
        const fwdHeaders = new Headers(proxyHeaders || {});
        if (cookies) fwdHeaders.set('Cookie', cookies);
        if (!fwdHeaders.has('User-Agent')) {
          fwdHeaders.set('User-Agent', 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0');
        }
        // Add body for POST/PATCH requests
        const proxyTimeoutMs = session_id ? 20000 : 65000;
        const fetchOpts = {
          method: method || 'GET',
          headers: fwdHeaders,
          signal: AbortSignal.timeout(proxyTimeoutMs),
        };
        if (body.body && (method === 'POST' || method === 'PATCH' || method === 'PUT')) {
          fetchOpts.body = body.body;
        }
        const proxyRes = await fetch(targetUrl, fetchOpts);
        const respBody = await proxyRes.arrayBuffer();
        return new Response(respBody, {
          status: 200,
          headers: {
            'Content-Type': 'application/octet-stream',
            'X-Proxy-Status': String(proxyRes.status),
            'X-Proxy-Content-Type': proxyRes.headers.get('Content-Type') || '',
            ...corsHeaders(request),
          },
        });
      } catch (e) {
        return new Response('Proxy error: ' + e.message, { status: 502 });
      }
    }

    // ─── JWXT direct proxy test ──────────────────────────────
    if (path === 'jwxt-test') {
      if (!authorizeDiagnostics(request, env)) return errorResponse('Not found', 404, request);
      const sessionId = request.headers.get('X-Session-Id');
      if (!sessionId) return errorResponse('Missing X-Session-Id', 400, request);
      const session = await getLocalSession(request, env);
      if (!session || !session.cookies) return errorResponse('No session cookies found', 404, request);

      const jwxtUrl = `${JWXT_BASE}/xtgl/index_initMenu.html`;
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
      if (!authorizeDiagnostics(request, env)) return errorResponse('Not found', 404, request);
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
        account = account || body.studentId || body.student_id || body.username;

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

        let sessionInfo;
        try {
          sessionInfo = await createPersistentSession(result, account, env);
        } catch (error) {
          console.error('[auto-login] 会话持久化失败', { error: error.message });
          return errorResponse(`会话创建失败: ${error.message}`, 503, request);
        }

        return jsonResponse({
          status: 'ok',
          sessionId: sessionInfo.sessionId,
          isAdmin: sessionInfo.isAdmin === true,
          studentName: result.studentName,
          studentId: null,
          credentialToken: result.credentialToken,
          ...(shouldReturnJwxtCookies(request) ? { jwxtCookies: result.cookies } : {}),
          ehallCookies: result.ehallCookies,
          ehallAuthToken: result.ehallAuthToken,
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
          credentials = await decryptCredentials(credentialToken, key, Date.now());
        } catch (e) {
          return errorResponse('凭据已失效，请重新登录', 401, request);
        }

        // Perform CAS auto-login with decrypted credentials
        const result = await casAutoLogin(credentials.account, credentials.password, env);

        if (result.error) {
          return errorResponse(result.error, 401, request);
        }

        let sessionInfo;
        try {
          sessionInfo = await createPersistentSession(result, credentials.account, env);
        } catch (error) {
          console.error('[relogin] 会话持久化失败', { error: error.message });
          return errorResponse(`会话创建失败: ${error.message}`, 503, request);
        }

        return jsonResponse({
          status: 'ok',
          sessionId: sessionInfo.sessionId,
          isAdmin: sessionInfo.isAdmin === true,
          studentName: result.studentName,
          studentId: null,
          credentialToken: result.credentialToken || credentialToken,
          ...(shouldReturnJwxtCookies(request) ? { jwxtCookies: result.cookies } : {}),
          ehallCookies: result.ehallCookies,
          ehallAuthToken: result.ehallAuthToken,
        }, 200, request);
      } catch (e) {
        return errorResponse(`重新登录失败: ${e.message}`, 500, request);
      }
    }

    // ─── Logout (edge + backend) ───────────────────────────────
    if (path === 'auth/logout' && request.method === 'POST') {
      const sessionId = request.headers.get('X-Session-Id');
      if (!sessionId) {
        return errorResponse('缺少会话标识', 400, request);
      }
      try {
        const localSession = await getLocalSession(request, env);
        const upstreamRequest = localSession
          ? injectSessionCookies(request, localSession)
          : request;
        const response = await proxyToVercel(
          upstreamRequest,
          env,
          new URL(request.url),
          !!localSession
        );
        await deleteSessionFromStores(sessionId, localSession, env);
        return response;
      } catch (error) {
        console.error(
          `[logout] Failed to revoke session ${sessionId.slice(0, 8)}: ${error.message}`
        );
        return errorResponse('退出登录失败，请重试', 503, request);
      }
    }

    // ─── Edge academic API: /me ──────────────────────────────
    // Handle student info directly at the Worker edge so JWXT cookies
    // (IP-bounded to the Worker's IP) remain valid.  Extracts ALL fields
    // that the Flutter StudentInfo model expects (17+ fields).
    if (path === 'me' && request.method === 'GET') {
      const session = await getLocalSession(request, env);
      if (session && session.cookies) {
        try {
          const [jwxtRes, html] = await fetchGbkText(`${JWXT_BASE}/xsxxxggl/xsgrxxwh_cxXsgrxx.html`, {
            headers: {
              'Cookie': session.cookies,
              'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
              'Referer': JWXT_REFERER,
            },
            signal: AbortSignal.timeout(15000),
          });
          if (jwxtRes && jwxtRes.ok && html) {
            // Extract student info from JWXT info page HTML
            // JWXT HTML structure has changed over time — elements may contain
            // nested <span>, <label>, or other tags.  We capture the full raw
            // inner HTML and strip all tags, rather than using a lazy [^<]+
            // which truncates at the first nested element.
            const getField = (id) => {
              // Match from id="col_*" through opening tag > to next </tag>
              const re = new RegExp(`id="${id}"[^>]*>([\\s\\S]*?)<\\/`, 'i');
              const m = html.match(re);
              if (!m) return null;
              // Strip all HTML tags, decode common entities, collapse whitespace
              return m[1]
                .replace(/<[^>]+>/g, '')
                .replace(/&nbsp;/g, ' ')
                .replace(/&lt;/g, '<')
                .replace(/&gt;/g, '>')
                .replace(/&amp;/g, '&')
                .replace(/\s+/g, ' ')
                .trim();
            };
            // Try multiple possible HTML element IDs for each field
            const getFieldMulti = (ids) => {
              for (const id of ids) {
                const v = getField(id);
                if (v) return v;
              }
              return null;
            };
            const studentInfo = {
              studentId: getField('col_xh') || '',
              name: getField('col_xm') || '',
              college: getFieldMulti(['col_jg_id', 'col_jg', 'col_xy', 'col_xyName']) || null,
              major: getFieldMulti(['col_zyh_id', 'col_zyfx_id', 'col_zy', 'col_zymc']) || null,
              className: getFieldMulti(['col_bh_id', 'col_bh', 'col_bj']) || null,
              grade: getFieldMulti(['col_njdm_id', 'col_nj']) || null,
              gender: getField('col_xbm') || null,
              idNumber: getField('col_zjhm') || null,
              birthDate: getField('col_csrq') || null,
              ethnicity: getField('col_mzm') || null,
              politicalStatus: getField('col_zzmmm') || null,
              enrollDate: getField('col_rxrq') || null,
              nativePlace: getField('col_jg') || null,
              studentStatus: getField('col_xjztdm') || null,
              educationLevel: getField('col_pyccdm') || null,
              phone: getField('col_sjhm') || null,
              email: getField('col_dzyx') || null,
              address: getField('col_jtdz') || null,
              // Extract photo URL if present
              photoDataUrl: null, // populated below after async fetch
            };
            // Extract photo URL from HTML, then fetch actual photo as base64
            const photoUrl = extractPhotoUrl(html);
            if (photoUrl && session.cookies) {
              try {
                const photoFullUrl = photoUrl.startsWith('http') ? photoUrl :
                  JWXT_ORIGIN + (photoUrl.startsWith('/') ? '' : '/') + photoUrl;
                const photoRes = await fetch(photoFullUrl, {
                  headers: {
                    'Cookie': session.cookies,
                    'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
                    'Referer': JWXT_REFERER,
                  },
                  signal: AbortSignal.timeout(10000),
                });
                if (photoRes && photoRes.ok) {
                  const photoBuf = await photoRes.arrayBuffer();
                  const photoBytes = new Uint8Array(photoBuf);
                  // Build base64 data URL
                  let b64 = '';
                  for (let i = 0; i < photoBytes.length; i++) {
                    b64 += String.fromCharCode(photoBytes[i]);
                  }
                  b64 = btoa(b64);
                  const contentType = photoRes.headers.get('Content-Type') || 'image/jpeg';
                  studentInfo.photoDataUrl = `data:${contentType};base64,${b64}`;
                }
              } catch (e) {
                console.warn(`[edge-me] Photo fetch failed: ${e.message}`);
              }
            }
            // Only return if we got at least a name or student ID
            if (studentInfo.name || studentInfo.studentId) {
              return jsonResponse(studentInfo, 200, request);
            }
          }
        } catch (e) {
          console.warn(`[edge-me] JWXT direct fetch failed: ${e.message}`);
        }
      }
      // Fall through to Vercel if edge fetch failed
    }

    // ─── Helper: parse notice items from JWXT news page HTML ────
    function decodeHtmlText(value) {
      return String(value || '')
        .replace(/&nbsp;/gi, ' ')
        .replace(/&amp;/gi, '&')
        .replace(/&lt;/gi, '<')
        .replace(/&gt;/gi, '>')
        .replace(/&quot;/gi, '"')
        .replace(/&#39;/gi, "'")
        .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(parseInt(code, 10)))
        .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCharCode(parseInt(code, 16)));
    }

    function stripHtml(value) {
      return decodeHtmlText(String(value || '').replace(/<[^>]+>/g, ' '))
        .replace(/\s+/g, ' ')
        .trim();
    }

    function attrValue(attrs, name) {
      const re = new RegExp(`${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i');
      const match = String(attrs || '').match(re);
      return match ? (match[2] || match[3] || match[4] || '').trim() : '';
    }

    function absoluteJwxtUrl(href, pageUrl) {
      if (!href) return '';
      const raw = decodeHtmlText(href).trim();
      const lower = raw.toLowerCase();
      if (!raw || raw === '#' || lower.startsWith('javascript:') || lower.startsWith('mailto:')) {
        return '';
      }
      try {
        return new URL(raw, pageUrl || JWXT_BASE + '/').toString();
      } catch (e) {
        return '';
      }
    }

    function noticeCategory(title, fallback = '通知公告') {
      if (/考试/.test(title) && !/考试安排/.test(title)) return '考试通知';
      if (/选课/.test(title) || /撤课/.test(title) || /增班/.test(title)) return '选课通知';
      if (/成绩/.test(title)) return '成绩通知';
      if (/考勤/.test(title) || /缺勤/.test(title)) return '考勤通知';
      if (/学籍/.test(title)) return '学籍通知';
      if (/评教/.test(title)) return '评教通知';
      if (/待办|申请|已办|待阅|已阅|草稿/.test(title)) return '办事大厅·消息';
      return fallback;
    }

    function parseNoticeItems(html, pageUrl, fallbackCategory = '通知公告') {
      const items = [];
      // JWXT news page lists notices with <a> links
      const linkRe = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
      let match;
      while ((match = linkRe.exec(html)) !== null) {
        const attrs = match[1] || '';
        const body = match[2] || '';
        const href = attrValue(attrs, 'href') || attrValue(attrs, 'data-url') || attrValue(attrs, 'url');
        const title = stripHtml(attrValue(attrs, 'title') || body);
        if (!title || title.length < 2) continue;
        const absoluteUrl = absoluteJwxtUrl(href, pageUrl);
        if (!absoluteUrl) continue;
        // Look for date near the link (within ~300 chars after)
        const linkEnd = match.index + match[0].length;
        const nearby = html.substring(linkEnd, linkEnd + 300);
        const dateMatch = nearby.match(/(\d{4}[-/]\d{1,2}[-/]\d{1,2})/);
        items.push({
          category: noticeCategory(title, fallbackCategory),
          title,
          date: dateMatch ? dateMatch[1] : null,
          url: absoluteUrl,
          summary: null,
        });
      }
      return dedupeNoticeItems(items);
    }

    function extractNoticeMoreUrls(html, pageUrl) {
      const urls = new Set();
      const tagRe = /<([a-z][\w:-]*)\b([^>]*)>([\s\S]*?)<\/\1>/gi;
      let match;
      while ((match = tagRe.exec(html)) !== null) {
        const attrs = match[2] || '';
        const text = stripHtml(match[3] || '');
        const marker = `${attrValue(attrs, 'class')} ${attrValue(attrs, 'id')}`.toLowerCase();
        if (!text.includes('更多') && !marker.includes('more') && !marker.includes('title-more')) {
          continue;
        }
        const direct = attrValue(attrs, 'href') || attrValue(attrs, 'data-url') || attrValue(attrs, 'url');
        const onclick = attrValue(attrs, 'onclick');
        const scriptUrl = onclick.match(/['"]([^'"]+\.html(?:\?[^'"]*)?)['"]/i)?.[1] || '';
        const absolute = absoluteJwxtUrl(direct || scriptUrl, pageUrl);
        if (absolute) urls.add(absolute);
      }
      const scriptRe = /(?:location\.href|window\.location(?:\.href)?)\s*=\s*['"]([^'"]+\.html(?:\?[^'"]*)?)['"]/gi;
      while ((match = scriptRe.exec(html)) !== null) {
        const absolute = absoluteJwxtUrl(match[1], pageUrl);
        if (absolute) urls.add(absolute);
      }
      return Array.from(urls);
    }

    function dedupeNoticeItems(items) {
      const seen = new Set();
      return items.filter(item => {
        const key = `${item.title}|${item.url}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
    }

    function mergeNoticeItems(...groups) {
      return dedupeNoticeItems(groups.flat().filter(Boolean));
    }

    function extractEhallRecords(payload, depth = 0) {
      if (!payload || depth > 5) return [];
      if (Array.isArray(payload)) return payload.filter(item => item && typeof item === 'object');
      if (typeof payload !== 'object') return [];
      for (const key of ['records', 'rows', 'list', 'items', 'dataList', 'resultList']) {
        if (Array.isArray(payload[key])) return payload[key];
      }
      for (const key of ['data', 'result', 'page', 'body']) {
        const nested = extractEhallRecords(payload[key], depth + 1);
        if (nested.length > 0) return nested;
      }
      return [];
    }

    function absoluteEhallUrl(raw) {
      if (!raw) return null;
      const value = String(raw).trim();
      if (!value || value === '#') return null;
      try {
        return new URL(value, EHALL_URL + '/').toString();
      } catch (e) {
        return null;
      }
    }

    function firstEhallText(record, keys) {
      for (const key of keys) {
        const value = record[key];
        if (value !== undefined && value !== null && String(value).trim()) {
          return String(value).trim();
        }
      }
      return null;
    }

    function ehallServiceUrl(record, id, section) {
      const direct = firstEhallText(record, ['url', 'link', 'detailUrl', 'formUrl', 'applyUrl', 'appUrl', 'pcUrl', 'mobileUrl', 'href']);
      if (direct && direct !== '无') {
        const absolute = absoluteEhallUrl(direct);
        if (absolute) return absolute;
      }
      if (id) {
        return `${EHALL_URL}/#/affairs/copyAllAffairs/guide/${encodeURIComponent(id)}?id=${section}`;
      }
      return `${EHALL_URL}/#/affairs/copyAllAffairs?id=${section}`;
    }

    function normalizeEhallService(record, section) {
      const title = firstEhallText(record, [
        'appName', 'name', 'affairName', 'serviceName', 'taskName',
        'title', 'processName', 'app_name', 'affair_name'
      ]);
      if (!title) return null;
      const id = firstEhallText(record, [
        'id', 'appId', 'app_id', 'affairId', 'wf_num',
        'taskId', 'processId', 'businessId'
      ]) || title;
      const department = firstEhallText(record, [
        'departmentName', 'department', 'deptName', 'deptNames',
        'applyDeptName', 'unitName', 'orgName', 'ownerDeptName', 'dept_name'
      ]);
      const type = firstEhallText(record, [
        'type', 'typeName', 'categoryName', 'affairTypeName', 'businessTypeName'
      ]);
      const rawTags = [record.tagName, record.tags, record.label, record.businessType]
        .flatMap(value => Array.isArray(value) ? value : String(value || '').split(/[,\s，、/]+/))
        .map(value => String(value).trim())
        .filter(Boolean);
      return {
        id: String(id),
        title,
        department,
        type,
        tags: Array.from(new Set(rawTags)).slice(0, 6),
        summary: firstEhallText(record, [
          'describe', 'description', 'summary', 'remark', 'serviceObject', 'guide'
        ]),
        url: ehallServiceUrl(record, String(id), section),
      };
    }

    async function fetchEhallServicesFromEdge(session, env, {
      label,
      section,
      params: serviceParams,
      pageSize = 100,
      timeoutMs = 15000,
    }) {
      const timestamp = String(Date.now());
      const csrfKey = env.EHALL_CSRF_KEY || 'lianyi2019';
      const params = new URLSearchParams({
        pageNum: '1',
        pageSize: String(pageSize),
        ...serviceParams,
        csrfTimestamp: timestamp,
        csrfToken: md5(`timestamp=${timestamp},key=${csrfKey}`),
      });
      const resp = await fetch(`${EHALL_URL}/api/affair/uis/affairs?${params.toString()}`, {
        method: 'GET',
        headers: {
          'Cookie': session.ehallCookies,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          'Accept': 'application/json, text/plain, */*',
          'Referer': EHALL_URL + '/',
        },
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!resp.ok) {
        throw new Error(`eHall ${label} returned ${resp.status}`);
      }
      const text = await resp.text();
      const payload = JSON.parse(text);
      const meta = payload && typeof payload === 'object' ? payload.meta : null;
      if (meta && meta.success === false) {
        throw new Error(String(meta.message || `eHall ${label} rejected`));
      }
      const seen = new Set();
      return extractEhallRecords(payload)
        .map(record => normalizeEhallService(record, section))
        .filter(item => {
          if (!item) return false;
          const key = item.id || item.title;
          if (seen.has(key)) return false;
          seen.add(key);
          return true;
        });
    }

    async function fetchEhallApplicationsFromEdge(session, env) {
      const primary = await fetchEhallServicesFromEdge(session, env, {
        label: 'applications',
        section: 'yyzx',
        params: { isCustom: '0', terminal: '1', appStatus: '1' },
        pageSize: 100,
      });
      if (primary.length > 0) return primary;
      return fetchEhallServicesFromEdge(session, env, {
        label: 'applications',
        section: 'yyzx',
        params: { isCustom: '0', terminal: '1' },
        pageSize: 100,
      });
    }

    async function fetchEhallAffairsFromEdge(session, env) {
      return fetchEhallServicesFromEdge(session, env, {
        label: 'affairs',
        section: 'bsdt',
        params: {},
        pageSize: 100,
      });
    }

    // ─── Helper: extract base64 student photo from info page HTML ─
    function extractPhotoUrl(html) {
      // Look for img tags with base64 photo data
      const imgMatch = html.match(/<img[^>]+src="(data:image\/[^"]+)"[^>]*>/i);
      if (imgMatch) return imgMatch[1];
      // Alternative: look for background-image style with data URL
      const bgMatch = html.match(/background-image\s*:\s*url\(["']?(data:image\/[^"')]+)["']?\)/i);
      if (bgMatch) return bgMatch[1];
      // JWXT photo endpoint pattern: photo_cxEncodedXszp?...zplx=rxhzp
      const urlMatch = html.match(/(?:src|href)=["']([^"']*photo_cxEncodedXszp[^"']*zplx=rxhzp[^"']*)["']/i);
      if (urlMatch) return urlMatch[1];
      return null;
    }

    // ─── Normalize JWXT raw fields → Flutter-expected format ─────
    function parseSectionRange(val) {
      if (val == null) return [null, null];
      const s = String(val);
      const dash = s.indexOf('-');
      if (dash > 0) {
        return [parseInt(s.substring(0, dash)) || null, parseInt(s.substring(dash + 1)) || null];
      }
      const n = parseInt(s);
      return [n || null, n || null];
    }

    function normalizeGradeItem(item) {
      return {
        courseName: item.kcmc || item.courseName || item.name || '',
        score: (item.cj != null ? String(item.cj) : null) || item.score || null,
        credit: (item.xf != null ? String(item.xf) : null) || item.credit || null,
        gradePoint: (item.jd != null ? String(item.jd) : null) || item.gradePoint || null,
        term: item.xqmc || item.xq || item.term || null,
      };
    }

    function normalizeScheduleCourse(item) {
      const [startSec, endSec] = parseSectionRange(item.ksjc || item.jcs || item.jc || item.startSection);
      return {
        name: item.kcmc || item.name || item.courseName || '',
        teacher: item.jsxx || item.jsxm || item.xm || item.teacher || null,
        classroom: item.cdmc || item.classroom || item.location || null,
        weekday: item.xqj || item.weekday || item.weekDay || null,
        startSection: startSec || item.startSection || null,
        endSection: endSec || item.endSection || null,
        weeks: item.zcd || item.weeks || item.week || null,
        kcbmc: item.kcbmc || null,
        raw: item,
      };
    }

    function normalizeExamItem(item) {
      const time = item.kssj || item.time || item.examTime || '';
      let date = item.date || item.examDate || '';
      // Force extract date from time if date is missing/empty
      // JWXT sends time in "YYYY-MM-DD(HH:MM-HH:MM)" or "YYYY-MM-DD HH:MM-HH:MM"
      if ((!date || date.length < 8) && time) {
        const parenIdx = time.indexOf('(');
        const spaceIdx = time.indexOf(' ');
        const sepIdx = parenIdx > 0 ? parenIdx : (spaceIdx > 0 ? spaceIdx : -1);
        if (sepIdx > 0) date = time.substring(0, sepIdx);
        else if (time.length >= 10 && time[4] === '-') date = time.substring(0, 10);
      }
      let weekday = item.weekday || item.weekDay || item.xqj || '';
      if (!weekday && date) {
        try {
          const dt = new Date(date);
          const names = ['周日','周一','周二','周三','周四','周五','周六'];
          weekday = names[dt.getDay()] || '';
        } catch (e) {}
      }
      return {
        courseName: item.kcmc || item.courseName || item.name || '',
        name: item.kcmc || item.courseName || item.name || '',
        date: date,
        weekday: weekday,
        time: time.replace('(', ' ').replace(')', ''), // normalize "2026-07-10(09:30-11:00)" → "2026-07-10 09:30-11:00"
        location: item.cdmc || item.location || item.examPlace || null,
        seat: (item.zwh != null ? String(item.zwh) : null) || item.seat || item.seatNo || null,
        type: item.ksmc || item.ksfs || item.type || item.kslx || null,
        credit: (item.xf != null ? String(item.xf) : '') || item.credit || '',
        campus: item.cdxqmc || item.campus || null,
        remark: item.ksbz || item.remark || null,
      };
    }

    function normalizeAttendanceItem(item) {
      return {
        courseName: item.kcmc || item.courseName || item.name || '',
        courseCode: item.kch || item.courseCode || null,
        academicYear: item.xnmc || item.xn || item.academicYear || null,
        term: String(item.xqmc || item.xq || item.term || ''),
        normal: parseInt(item.cs_01 || item.normal || 0) || 0,
        late: parseInt(item.cs_02 || item.late || 0) || 0,
        leaveEarly: parseInt(item.cs_03 || item.leaveEarly || 0) || 0,
        absent: parseInt(item.cs_04 || item.absent || 0) || 0,
        leave: parseInt(item.cs_05 || item.leave || 0) || 0,
        total: parseInt(item.totalresult || item.total || 0) || 0,
        records: [],
      };
    }

    function normalizeCreditItem(item) {
      const reqExp = parseFloat(item.yqxf_01 || item.requiredExpected || 0);
      const eleExp = parseFloat(item.yqxf_02 || item.electiveExpected || 0);
      const othExp = parseFloat(item.yqxf_03 || item.otherExpected || 0);
      const reqEar = parseFloat(item.sxxf_01 || item.requiredEarned || 0);
      const eleEar = parseFloat(item.sxxf_02 || item.electiveEarned || 0);
      const othEar = parseFloat(item.sxxf_03 || item.otherEarned || 0);
      return {
        studentId: String(item.xh || item.studentId || ''),
        name: item.xm || item.name || null,
        college: item.jgmc || item.college || null,
        major: item.zymc || item.major || null,
        grade: String(item.nj || item.grade || ''),
        totalCredit: String(item.zdxf || item.totalCredit || ''),
        requiredCredit: String(item.bxxf || item.requiredCredit || ''),
        selectedCredit: String(item.xkxf || item.selectedCredit || ''),
        requiredExpected: reqExp,
        electiveExpected: eleExp,
        otherExpected: othExp,
        requiredEarned: reqEar,
        electiveEarned: eleEar,
        otherEarned: othEar,
        totalExpected: reqExp + eleExp + othExp,
        totalEarned: reqEar + eleEar + othEar,
      };
    }

    function normalizeResultList(items, path) {
      if (!Array.isArray(items)) return items;
      if (path === 'exams') return items.map(normalizeExamItem);
      if (path === 'grades') return items.map(normalizeGradeItem);
      if (path === 'schedule') return items.map(normalizeScheduleCourse);
      if (path === 'attendance') return items.map(normalizeAttendanceItem);
      if (path === 'credits') return items.map(normalizeCreditItem);
      return items;
    }

    function extractAcademicItems(data) {
      if (Array.isArray(data)) return data;
      if (!data || typeof data !== 'object') return null;
      for (const key of ['items', 'kbList', 'rows', 'list', 'data']) {
        if (Array.isArray(data[key])) return data[key];
        if (data[key] && typeof data[key] === 'object') {
          const nested = extractAcademicItems(data[key]);
          if (nested) return nested;
        }
      }
      return null;
    }

    function unwrapCreditObject(data) {
      if (data && data.data && typeof data.data === 'object' && !Array.isArray(data.data)) {
        return data.data;
      }
      return data;
    }

    function dashboardCacheKey(sessionId, module, year, term) {
      return `dashboard:${sessionId}:${module}:${year || ''}:${term || ''}`;
    }

    async function loadDashboardCache(env, key, ttlSeconds) {
      const local = localAcademicCache.get(key);
      if (local && Date.now() - local.cachedAt < ttlSeconds * 1000) return local;
      try {
        if (env && env.SESSIONS_KV) {
          const raw = await env.SESSIONS_KV.get(key);
          if (raw) {
            const data = JSON.parse(raw);
            localAcademicCache.set(key, data);
            return data;
          }
        }
      } catch (e) {
        console.warn(`[dashboard-cache] load failed for ${key}: ${e.message}`);
      }
      return null;
    }

    async function saveDashboardCache(env, key, data, ttlSeconds) {
      const payload = { data, cachedAt: Date.now() };
      localAcademicCache.set(key, payload);
      try {
        if (env && env.SESSIONS_KV) {
          await env.SESSIONS_KV.put(key, JSON.stringify(payload), { expirationTtl: ttlSeconds });
        }
      } catch (e) {
        console.warn(`[dashboard-cache] save failed for ${key}: ${e.message}`);
      }
    }

    function withTimeout(promise, timeoutMs, label) {
      return Promise.race([
        promise,
        new Promise((_, reject) => setTimeout(
          () => reject(new Error(`${label} timeout after ${timeoutMs}ms`)),
          timeoutMs,
        )),
      ]);
    }

    async function dashboardModule({
      name,
      sessionId,
      year,
      term,
      ttlSeconds,
      timeoutMs,
      fetcher,
    }) {
      const started = Date.now();
      const key = dashboardCacheKey(sessionId, name, year, term);
      // SWR：TTL 内命中缓存则立即返回（stale），后台静默刷新缓存。
      // 前端 hasUsableData 将 stale 视为可用数据并显示缓存标识。
      const cached = await loadDashboardCache(env, key, ttlSeconds);
      if (cached && cached.data !== undefined) {
        if (context && typeof context.waitUntil === 'function') {
          context.waitUntil((async () => {
            try {
              const fresh = await withTimeout(fetcher(), timeoutMs, `dashboard:${name}:refresh`);
              await saveDashboardCache(env, key, fresh, ttlSeconds);
            } catch (e) {
              console.warn(`[dashboard] 后台刷新失败 ${name}: ${e && e.message ? e.message : e}`);
            }
          })());
        }
        return {
          status: 'stale',
          data: cached.data,
          source: 'edge-cache',
          cachedAt: new Date(cached.cachedAt).toISOString(),
          durationMs: Date.now() - started,
        };
      }
      try {
        const data = await withTimeout(fetcher(), timeoutMs, `dashboard:${name}`);
        const status = Array.isArray(data) && data.length === 0 ? 'empty' : 'ok';
        await saveDashboardCache(env, key, data, ttlSeconds);
        return {
          status,
          data,
          source: 'edge',
          durationMs: Date.now() - started,
        };
      } catch (e) {
        return {
          status: 'error',
          data: null,
          source: 'edge',
          error: e && e.message ? e.message : String(e),
          durationMs: Date.now() - started,
        };
      }
    }

    function academicRequestConfig(module, year, term, account) {
      const termMap = { '1': '3', '2': '12', '3': '16' };
      const xqm = termMap[String(term)] || '';
      const nd = String(Date.now());
      const baseParams = {
        xnm: String(year),
        xqm,
        _search: 'false',
        nd,
        'queryModel.showCount': '100',
        'queryModel.currentPage': '1',
        'queryModel.sortName': '',
        'queryModel.sortOrder': 'asc',
        time: '1',
      };
      if (module === 'exams') {
        return {
          url: `${JWXT_BASE}/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105`,
          body: new URLSearchParams({ ...baseParams, ksmcdmb_id: '', kch: '', kc: '', ksrq: '' }),
        };
      }
      if (module === 'schedule') {
        return {
          url: `${JWXT_BASE}/kbcx/xskbcx_cxXsKb.html`,
          body: new URLSearchParams({ ...baseParams, kzlx: 'ck' }),
        };
      }
      if (module === 'grades') {
        return {
          url: `${JWXT_BASE}/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005`,
          body: new URLSearchParams({ ...baseParams, kch: '', kc: '' }),
        };
      }
      if (module === 'credits' && account) {
        return {
          url: `${JWXT_BASE}/design/funcData_cxFuncDataList.html?func_widget_guid=555A63AA3F6BB8E4E065CAE6002842BA&gnmkdm=N255022`,
          body: new URLSearchParams({
            gnmkdm: 'N255022',
            xh: account,
            'queryModel.showCount': '15',
            'queryModel.currentPage': '1',
            'queryModel.sortName': ' ',
            'queryModel.sortOrder': 'asc',
          }),
        };
      }
      if (module === 'attendance' && account) {
        return {
          url: `${JWXT_BASE}/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html?doType=query&gnmkdm=N254315`,
          body: new URLSearchParams({
            xh: account,
            xm: '',
            xh_id: '',
            xnm: String(year),
            xqm,
            kch: '',
            kch_id: '',
            gnmkdm: 'N254315',
            'queryModel.showCount': '100',
            'queryModel.currentPage': '1',
            'queryModel.sortName': '',
            'queryModel.sortOrder': 'asc',
          }),
        };
      }
      return null;
    }

    async function fetchDashboardAcademic(module, session, year, term) {
      const config = academicRequestConfig(module, year, term, session.account);
      if (!config) return module === 'attendance' ? { status: 'empty', items: [] } : [];
      const [jwxtRes, data] = await fetchGbkJson(config.url, {
        method: 'POST',
        headers: {
          'Cookie': session.cookies,
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          'Referer': JWXT_REFERER,
        },
        body: config.body.toString(),
        signal: AbortSignal.timeout(DASHBOARD_DIRECT_TIMEOUT_MS),
      });
      if (!jwxtRes || !jwxtRes.ok || !data) {
        if (module === 'schedule' && jwxtRes && jwxtRes.ok) {
          return [];
        }
        throw new Error(`JWXT ${module} returned ${jwxtRes ? jwxtRes.status : 'null'}`);
      }
      if (module === 'attendance') {
        const items = Array.isArray(data.items) ? data.items : extractAcademicItems(data) || [];
        return { status: 'ok', items: normalizeResultList(items, module) };
      }
      const items = extractAcademicItems(data);
      if (items) return normalizeResultList(items, module);
      if (module === 'credits' && data && typeof data === 'object') {
        const creditData = unwrapCreditObject(data);
        const totalResult = creditData.totalResult ?? creditData.totalCount ?? -1;
        if (Number(totalResult) === 0) return [];
        return normalizeResultList([creditData], module);
      }
      if (module === 'schedule') return [];
      throw new Error(`JWXT ${module} returned unexpected format`);
    }

    function extractDashboardStudentInfo(html) {
      const getField = (id) => {
        const re = new RegExp(`id="${id}"[^>]*>([\\s\\S]*?)<\\/`, 'i');
        const m = html.match(re);
        if (!m) return null;
        return m[1]
          .replace(/<[^>]+>/g, '')
          .replace(/&nbsp;/g, ' ')
          .replace(/&lt;/g, '<')
          .replace(/&gt;/g, '>')
          .replace(/&amp;/g, '&')
          .replace(/\s+/g, ' ')
          .trim();
      };
      const getFieldMulti = (ids) => {
        for (const id of ids) {
          const v = getField(id);
          if (v) return v;
        }
        return null;
      };
      return {
        studentId: getField('col_xh') || '',
        name: getField('col_xm') || '',
        college: getFieldMulti(['col_jg_id', 'col_jg', 'col_xy', 'col_xyName']) || null,
        major: getFieldMulti(['col_zyh_id', 'col_zyfx_id', 'col_zy', 'col_zymc']) || null,
        className: getFieldMulti(['col_bh_id', 'col_bh', 'col_bj']) || null,
        grade: getFieldMulti(['col_njdm_id', 'col_nj']) || null,
        gender: getField('col_xbm') || null,
        idNumber: getField('col_zjhm') || null,
        birthDate: getField('col_csrq') || null,
        ethnicity: getField('col_mzm') || null,
        politicalStatus: getField('col_zzmmm') || null,
        enrollDate: getField('col_rxrq') || null,
        nativePlace: getField('col_jg') || null,
        studentStatus: getField('col_xjztdm') || null,
        educationLevel: getField('col_pyccdm') || null,
        phone: getField('col_sjhm') || null,
        email: getField('col_dzyx') || null,
        address: getField('col_jtdz') || null,
        photoDataUrl: null,
      };
    }

    async function fetchDashboardMe(session) {
      const [jwxtRes, html] = await fetchGbkText(`${JWXT_BASE}/xsxxxggl/xsgrxxwh_cxXsgrxx.html`, {
        headers: {
          'Cookie': session.cookies,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          'Referer': JWXT_REFERER,
        },
        signal: AbortSignal.timeout(DASHBOARD_DIRECT_TIMEOUT_MS),
      });
      if (!jwxtRes || !jwxtRes.ok || !html) throw new Error('个人资料获取失败');
      const info = extractDashboardStudentInfo(html);
      if (!info.name && !info.studentId) throw new Error('个人资料为空');
      return info;
    }

    async function fetchDashboardNotices(session) {
      const newsUrl = `${JWXT_BASE}/xtgl/index_cxNews.html?localeKey=zh_CN`;
      const [newsRes, html] = await fetchGbkText(newsUrl, {
        headers: {
          'Cookie': session.cookies,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
          'Referer': JWXT_REFERER,
        },
        signal: AbortSignal.timeout(DASHBOARD_DIRECT_TIMEOUT_MS),
      });
      if (!newsRes || !newsRes.ok || !html) throw new Error('通知获取失败');
      return parseNoticeItems(html, newsUrl).slice(0, 20);
    }

    async function fetchDashboardBackend(path, request, session, timeoutMs) {
      const origin = vercelOrigin(env);
      const headers = buildVercelProxyHeaders(request);
      if (session.cookies) headers.set('Cookie', session.cookies);
      if (session.ehallCookies) headers.set('X-Ehall-Cookies', session.ehallCookies);
      if (session.account) headers.set('X-Student-Account', session.account);
      headers.set('X-Worker-Auth', '1');
      const resp = await fetch(new URL(path, origin), {
        method: 'GET',
        headers,
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!resp.ok) throw new Error(`${path} returned ${resp.status}`);
      return resp.json();
    }

    // ─── Dashboard snapshot ───────────────────────────────────
    if (path === 'dashboard' && request.method === 'GET') {
      const traceId = request.headers.get('X-GZUS-Trace-Id') ||
        `edge-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      const sessionId = request.headers.get('X-Session-Id') || '';
      const session = await getLocalSession(request, env);
      if (!sessionId || !session || !session.cookies) {
        return jsonResponse({ detail: '会话已过期，请重新登录', traceId }, 401, request);
      }
      const defaults = defaultAcademicPeriod();
      const year = url.searchParams.get('year') || defaults.year;
      const term = url.searchParams.get('term') || defaults.term;
      const modules = {};
      const jobs = {
        me: dashboardModule({
          name: 'me', sessionId, year, term, ttlSeconds: 86400,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardMe(session),
        }),
        schedule: dashboardModule({
          name: 'schedule', sessionId, year, term, ttlSeconds: 1800,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardAcademic('schedule', session, year, term),
        }),
        notices: dashboardModule({
          name: 'notices', sessionId, year, term, ttlSeconds: 300,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardNotices(session),
        }),
        attendance: dashboardModule({
          name: 'attendance', sessionId, year, term, ttlSeconds: 1800,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardAcademic('attendance', session, year, term),
        }),
        credits: dashboardModule({
          name: 'credits', sessionId, year, term, ttlSeconds: 1800,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardAcademic('credits', session, year, term),
        }),
        grades: dashboardModule({
          name: 'grades', sessionId, year, term, ttlSeconds: 1800,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardAcademic('grades', session, year, term),
        }),
        exams: dashboardModule({
          name: 'exams', sessionId, year, term, ttlSeconds: 1800,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardAcademic('exams', session, year, term),
        }),
        apps: dashboardModule({
          name: 'apps', sessionId, year, term, ttlSeconds: 600,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => session.ehallCookies ? fetchEhallApplicationsFromEdge(session, env) : [],
        }),
        progress: dashboardModule({
          name: 'progress', sessionId, year, term, ttlSeconds: 300,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => session.ehallCookies
            ? fetchDashboardBackend('/ehall/progress', request, session, DASHBOARD_BACKEND_TIMEOUT_MS)
            : { items: [] },
        }),
        ecard: dashboardModule({
          name: 'ecard', sessionId, year, term, ttlSeconds: 600,
          timeoutMs: DASHBOARD_MODULE_TIMEOUT_MS,
          fetcher: () => fetchDashboardBackend('/ecard/summary', request, session, DASHBOARD_BACKEND_TIMEOUT_MS),
        }),
      };
      const settled = await withTimeout(
        Promise.all(Object.entries(jobs).map(async ([name, promise]) => [name, await promise])),
        DASHBOARD_TOTAL_TIMEOUT_MS,
        'dashboard',
      ).catch(async (e) => {
        console.warn(`[dashboard] total timeout trace=${traceId}: ${e.message}`);
        return Promise.all(Object.entries(jobs).map(async ([name, promise]) => {
          try {
            return [name, await withTimeout(promise, 50, name)];
          } catch (err) {
            return [name, {
              status: 'error',
              data: null,
              source: 'edge',
              error: err && err.message ? err.message : String(err),
              durationMs: DASHBOARD_TOTAL_TIMEOUT_MS,
            }];
          }
        }));
      });
      for (const [name, value] of settled) modules[name] = value;
      modules.weather = { status: 'empty', data: null, source: 'client', durationMs: 0 };
      const response = jsonResponse({
        status: 'ok',
        generatedAt: new Date().toISOString(),
        traceId,
        modules,
      }, 200, request);
      response.headers.set('X-GZUS-Trace-Id', traceId);
      response.headers.set('Cache-Control', 'no-store');
      return response;
    }

    // ─── Edge academic API: /exams /schedule /grades /credits /attendance ─
    // Handle these at the Worker edge to avoid Vercel's 10-second
    // Hobby-plan timeout on the double-proxy chain.
    const academicPaths = { exams: true, schedule: true, grades: true, credits: true, attendance: true };
    if (academicPaths[path] && request.method === 'GET') {
      const sessionId = request.headers.get('X-Session-Id') || '';
      const session = await getLocalSession(request, env);
      let lastEdgeError = '';
      let lastEdgeStatus = null;
      if (session && session.cookies) {
        try {
          const urlParams = url.searchParams;
          const defaults = defaultAcademicPeriod();
          const year = urlParams.get('year') || defaults.year;
          const term = urlParams.get('term') || defaults.term;
          const cacheKey = academicCacheKey(sessionId, path, year, term);
          const termMap = { '1': '3', '2': '12', '3': '16' };
          const xqm = termMap[term] || '';
          const nd = String(Date.now());
          const baseParams = { xnm: year, xqm: xqm, _search: 'false', nd: nd,
            'queryModel.showCount': '100', 'queryModel.currentPage': '1',
            'queryModel.sortName': '', 'queryModel.sortOrder': 'asc', time: '1' };

          let jwxtUrl, postData;
          if (path === 'exams') {
            jwxtUrl = `${JWXT_BASE}/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105`;
            postData = new URLSearchParams({ ...baseParams, ksmcdmb_id: '', kch: '', kc: '', ksrq: '' });
          } else if (path === 'schedule') {
            jwxtUrl = `${JWXT_BASE}/kbcx/xskbcx_cxXsKb.html`;
            postData = new URLSearchParams({ ...baseParams, kzlx: 'ck' });
          } else if (path === 'grades') {
            jwxtUrl = `${JWXT_BASE}/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005`;
            postData = new URLSearchParams({ ...baseParams, kch: '', kc: '' });
          } else if (path === 'credits') {
            if (!session.account) {
              jwxtUrl = null; // fall through to Vercel
            } else {
              jwxtUrl = `${JWXT_BASE}/design/funcData_cxFuncDataList.html?func_widget_guid=555A63AA3F6BB8E4E065CAE6002842BA&gnmkdm=N255022`;
              postData = new URLSearchParams({ gnmkdm: 'N255022', xh: session.account,
                'queryModel.showCount': '15', 'queryModel.currentPage': '1',
                'queryModel.sortName': ' ', 'queryModel.sortOrder': 'asc' });
            }
          } else if (path === 'attendance') {
            // Attendance: POST to jxdmqkcx query endpoint
            if (!session.account) {
              jwxtUrl = null; // fall through to Vercel
            } else {
              jwxtUrl = `${JWXT_BASE}/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html?doType=query&gnmkdm=N254315`;
              postData = new URLSearchParams({
                xh: session.account, xm: '', xh_id: '',
                xnm: year, xqm: xqm, kch: '', kch_id: '',
                gnmkdm: 'N254315',
                'queryModel.showCount': '100', 'queryModel.currentPage': '1',
                'queryModel.sortName': '', 'queryModel.sortOrder': 'asc',
              });
            }
          }

          if (jwxtUrl) {
            const fetchAcademic = async () => {
              const [jwxtRes, data] = await fetchGbkJson(jwxtUrl, {
                method: 'POST',
                headers: {
                  'Cookie': session.cookies,
                  'Content-Type': 'application/x-www-form-urlencoded',
                  'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
                  'Referer': JWXT_REFERER,
                },
                body: postData.toString(),
                signal: AbortSignal.timeout(15000),
              });
              return { jwxtRes, data };
            };
            // 归一化 JWXT 响应为前端约定格式；无法识别时返回 null
            const normalizeAcademicData = (raw) => {
              // attendance returns { status: 'ok', items: [...] }
              if (path === 'attendance' && raw && raw.items) {
                return {
                  value: { status: 'ok', items: normalizeResultList(raw.items, path) },
                };
              }
              // Common JWXT response formats — normalize field names for Flutter.
              const academicItems = extractAcademicItems(raw);
              if (academicItems) {
                return { value: normalizeResultList(academicItems, path) };
              }
              // Single object (credits totals, etc.)
              if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
                if (path === 'schedule') {
                  return { value: [], emptyReason: 'schedule-without-items' };
                }
                if (path === 'credits') {
                  const creditData = unwrapCreditObject(raw);
                  const totalResult = creditData.totalResult ?? creditData.totalCount ?? -1;
                  return {
                    value: Number(totalResult) === 0
                      ? []
                      : normalizeResultList([creditData], path),
                  };
                }
                return { value: raw };
              }
              return null;
            };
            // 请求去重：同 cacheKey 的进行中请求（含 SWR 后台刷新）共享一个 Promise
            const startFetchAndCache = () => {
              let p = localAcademicInFlight.get(cacheKey);
              if (!p) {
                p = (async () => {
                  const { jwxtRes, data } = await fetchAcademic();
                  if (jwxtRes && jwxtRes.ok && data) {
                    const result = normalizeAcademicData(data);
                    if (result !== null) {
                      await saveAcademicCache(env, cacheKey, result.value);
                      return { ok: true, value: result.value, emptyReason: result.emptyReason, jwxtRes };
                    }
                  }
                  return { ok: false, jwxtRes };
                })();
                localAcademicInFlight.set(cacheKey, p);
                p.finally(() => {
                  if (localAcademicInFlight.get(cacheKey) === p) {
                    localAcademicInFlight.delete(cacheKey);
                  }
                });
              }
              return p;
            };
            // SWR：TTL 内命中缓存立即返回（边缘响应从秒级降到毫秒级），
            // 并通过 waitUntil 后台静默刷新缓存
            const cached = await loadAcademicCache(env, cacheKey);
            if (cached && cached.data !== undefined) {
              if (context && typeof context.waitUntil === 'function') {
                context.waitUntil(startFetchAndCache().catch(() => {}));
              }
              const resp = jsonResponse(cached.data, 200, request);
              resp.headers.set('X-Data-Source', 'edge-cache');
              resp.headers.set('X-Data-Cached-At', new Date(cached.cachedAt).toISOString());
              return resp;
            }
            const result = await startFetchAndCache();
            if (result.ok) {
              const resp = jsonResponse(result.value, 200, request);
              if (result.emptyReason) {
                resp.headers.set('X-Data-Source', 'edge-empty');
                resp.headers.set('X-Data-Reason', result.emptyReason);
              }
              return resp;
            }
            const jwxtRes = result.jwxtRes;
            if (jwxtRes && jwxtRes.ok) {
              lastEdgeError = 'JWXT returned unexpected data format';
              console.warn(`[edge-${path}] ${lastEdgeError}`);
            } else {
              lastEdgeStatus = jwxtRes ? jwxtRes.status : null;
              lastEdgeError = `JWXT returned ${lastEdgeStatus || 'null'} or invalid JSON`;
              console.warn(`[edge-${path}] ${lastEdgeError}`);
            }
          }
        } catch (e) {
          lastEdgeError = e && e.message ? e.message : String(e);
          console.warn(`[edge-${path}] JWXT direct fetch failed: ${lastEdgeError}`);
        }
        if (path === 'schedule') {
          const defaults = defaultAcademicPeriod();
          const year = url.searchParams.get('year') || defaults.year;
          const term = url.searchParams.get('term') || defaults.term;
          const cacheKey = academicCacheKey(sessionId, path, year, term);
          const cached = await loadAcademicCache(env, cacheKey);
          if (cached && cached.data) {
            const resp = jsonResponse(cached.data, 200, request);
            resp.headers.set('X-Data-Source', 'edge-cache');
            resp.headers.set('X-Data-Cached-At', new Date(cached.cachedAt).toISOString());
            return resp;
          }
          const resp = jsonResponse([], 200, request);
          resp.headers.set('X-Data-Source', 'edge-empty');
          resp.headers.set('X-Data-Reason', lastEdgeError || 'JWXT request failed');
          return resp;
        }
      }
      // Fall through to Vercel if edge fetch failed
    }

    // ─── Edge eHall services API ───────────────────────────────
    // These pages need fresh eHall data; failures return explicit errors
    // instead of empty lists so the app never treats a failed fetch as truth.
    if ((path === 'ehall/applications' || path === 'ehall/affairs') && request.method === 'GET') {
      const sessionId = request.headers.get('X-Session-Id') || '';
      const session = await getLocalSession(request, env);
      const kind = path === 'ehall/applications' ? 'applications' : 'affairs';
      if (!sessionId || !session || !session.ehallCookies) {
        return jsonResponse({
          detail: '办事大厅会话不可用，请重新登录',
          source: 'edge-ehall',
          kind,
        }, 401, request);
      }
      try {
        const items = kind === 'applications'
          ? await fetchEhallApplicationsFromEdge(session, env)
          : await fetchEhallAffairsFromEdge(session, env);
        await saveAcademicCache(env, `ehall-${kind}:${sessionId}`, items);
        const resp = jsonResponse(items, 200, request);
        resp.headers.set('X-Data-Source', 'edge-ehall');
        return resp;
      } catch (e) {
        const message = e && e.message ? e.message : String(e);
        const lowerMessage = message.toLowerCase();
        const status = lowerMessage.includes('timeout') || lowerMessage.includes('aborted') || lowerMessage.includes('timed out') ? 504 : 502;
        console.warn(`[edge-${kind}] eHall fetch failed: ${message}`);
        return jsonResponse({
          detail: '办事大厅数据获取失败，请稍后重试',
          source: 'edge-ehall',
          kind,
          error: message,
        }, status, request);
      }
    }

    // ─── Edge notices API ─────────────────────────────────────
    // Handle notices at the Worker edge to avoid Vercel timeout.
    if (path === 'notices' && request.method === 'GET') {
      const session = await getLocalSession(request, env);
      if (session && session.cookies) {
        try {
          const newsUrl = `${JWXT_BASE}/xtgl/index_cxNews.html?localeKey=zh_CN`;
          const noticeHeaders = {
            'Cookie': session.cookies,
            'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
            'Referer': JWXT_REFERER,
          };
          const isLoginPage = (value) => value.includes('login_slogin') || /<input[^>]*type\s*=\s*['"]password['"]/i.test(value);
          const [newsRes, html] = await fetchGbkText(newsUrl, {
            headers: noticeHeaders,
            signal: AbortSignal.timeout(15000),
          });
          if (newsRes && newsRes.ok && html) {
            // Check if we got a login page instead
            if (isLoginPage(html)) {
              console.warn('[edge-notices] JWXT returned login page, session may be expired');
            } else {
              const indexItems = parseNoticeItems(html, newsUrl);
              const moreUrls = extractNoticeMoreUrls(html, newsUrl);
              if (moreUrls.length === 0) {
                moreUrls.push(`${JWXT_BASE}/xtgl/xwck_cxMoreXwList.html`);
              }
              const moreItemsPromise = Promise.all(
                moreUrls.slice(0, 4).map(async (moreUrl) => {
                  try {
                    const [moreRes, moreHtml] = await fetchGbkText(moreUrl, {
                      headers: noticeHeaders,
                      signal: AbortSignal.timeout(15000),
                    });
                    if (moreRes && moreRes.ok && moreHtml && !isLoginPage(moreHtml)) {
                      return parseNoticeItems(moreHtml, moreUrl);
                    }
                  } catch (e) {
                    console.warn(`[edge-notices] more page fetch failed: ${e.message}`);
                  }
                  return [];
                })
              ).then(groups => groups.filter(group => group.length > 0));
              const dbsyItemsPromise = (async () => {
                try {
                  const dbsyUrl = `${JWXT_BASE}/xtgl/index_cxDbsy.html?localeKey=zh_CN`;
                  const [dbsyRes, dbsyHtml] = await fetchGbkText(dbsyUrl, {
                    headers: noticeHeaders,
                    signal: AbortSignal.timeout(15000),
                  });
                  if (dbsyRes && dbsyRes.ok && dbsyHtml && !isLoginPage(dbsyHtml)) {
                    return parseNoticeItems(dbsyHtml, dbsyUrl, '我的消息');
                  }
                } catch (e) {
                  console.warn(`[edge-notices] DBSY fetch failed: ${e.message}`);
                }
                return [];
              })();
              const ehallItemsPromise = (async () => {
                if (!session.ehallCookies) return [];
                try {
                  const origin = vercelOrigin(env);
                  const headers = new Headers(request.headers);
                  headers.set('Cookie', session.cookies);
                  headers.set('X-Ehall-Cookies', session.ehallCookies);
                  headers.set('X-Worker-Auth', '1');
                  if (session.account) headers.set('X-Student-Account', session.account);
                  const resp = await fetch(new URL('/ehall/tasks', origin), {
                    method: 'GET',
                    headers,
                    signal: AbortSignal.timeout(6000),
                  });
                  if (!resp.ok) return [];
                  const data = await resp.json();
                  return Array.isArray(data) ? data : [];
                } catch (e) {
                  console.warn(`[edge-notices] ehall tasks fetch failed: ${e.message}`);
                }
                return [];
              })();
              const [moreItemGroups, dbsyItems, ehallItems] = await Promise.all([
                moreItemsPromise,
                dbsyItemsPromise,
                ehallItemsPromise,
              ]);
              const items = mergeNoticeItems(...moreItemGroups, indexItems, dbsyItems, ehallItems);
              if (items.length > 0) {
                return jsonResponse(items, 200, request);
              }
            }
          }
        } catch (e) {
          console.warn(`[edge-notices] JWXT direct fetch failed: ${e.message}, falling through to Vercel`);
        }
      }
      // Fall through to Vercel if edge fetch failed
    }

    // ─── All other routes: proxy to Vercel ─────────────────────
    // Inject local session cookies if available (bypass Vercel's IP-bounded cookie issue).
    // Check memory first, then Cloudflare KV for cross-instance persistence.
    const sessionId = request.headers.get('X-Session-Id');
    const localSession = await getLocalSession(request, env);
    let hadLocalSession = !!localSession;
    if (localSession) {
      try {
        request = injectSessionCookies(request, localSession);
      } catch (e) {
        console.error(`[proxy] injectSessionCookies failed: ${e.message}`);
        // Fall through without injected cookies — Vercel will use DB-stored cookies
        hadLocalSession = false;
      }
    } else if (sessionId) {
      console.warn(`[proxy] No localSession found for sessionId=${sessionId.slice(0,8)}... — cookies will NOT be injected`);
    }
    return proxyToVercel(request, env, url, hadLocalSession);
  },
};

// ─── Decrypt password via Vercel (fast, < 1s) ──────────────────────
async function decryptPasswordOnVercel(encryptedPassword, keyId, env) {
  const origin = vercelOrigin(env);

  try {
    const res = await fetch(`${origin}/internal/decrypt-password`, {
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
async function createSessionOnBackend(loginResult, account, env) {
  const origin = vercelOrigin(env);

  try {
    const res = await fetch(`${origin}/internal/create-session`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Internal-Key': env.INTERNAL_API_KEY || '',
      },
      body: JSON.stringify({
        account,
        cookies: loginResult.cookies,
        ehall_cookies: loginResult.ehallCookies,
        ehall_auth_token: loginResult.ehallAuthToken,
        student_name: loginResult.studentName,
      }),
      signal: AbortSignal.timeout(30000),
    });
    if (res.ok) {
      const data = await res.json();
      // isAdmin 由后端 create-session 按 admin_users 白名单判定，透传给前端登录响应
      return { sessionId: data.sessionId, isAdmin: data.isAdmin === true };
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
  const origin = vercelOrigin(env);
  // Strip /api/ prefix for Vercel backend compatibility
  let upstreamPath = url.pathname;
  if (upstreamPath.startsWith('/api/')) {
    upstreamPath = upstreamPath.slice(4); // Remove /api
  }
  const upstreamUrl = new URL(upstreamPath + url.search, origin);
  const isEcardPath = upstreamPath.startsWith('/ecard/');
  const isSlowEhallPath = upstreamPath.startsWith('/ehall/leave/');
  const upstreamTimeoutMs = (isEcardPath || isSlowEhallPath) ? 65000 : 12000;

  if ((request.headers.get('Upgrade') || '').toLowerCase() === 'websocket') {
    return fetch(new Request(upstreamUrl, request));
  }

  // Save the original request body so we can re-create it for each retry.
  // request.body is a ReadableStream that can only be consumed once.
  let savedBody = null;
  try {
    if (request.body) {
      savedBody = await request.clone().text();
    }
  } catch {}

  // 仅幂等请求（GET/HEAD/OPTIONS）在 5xx 时重试；POST/PATCH 等非幂等操作
  // 直接透传结果，避免消费/请假提交等被重复执行。
  const isIdempotent = request.method === 'GET' || request.method === 'HEAD' || request.method === 'OPTIONS' || request.method === 'PUT';
  const maxRetries = isIdempotent ? 2 : 0;
  let lastError = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      // Re-create the upstream request for each attempt — body streams
      // can only be consumed once, so we MUST rebuild the request.
      let upstreamRequest;
      const upstreamHeaders = buildVercelProxyHeaders(request);
      if (savedBody !== null) {
        upstreamRequest = new Request(upstreamUrl, {
          method: request.method,
          headers: upstreamHeaders,
          body: savedBody,
        });
      } else {
        upstreamRequest = new Request(upstreamUrl, {
          method: request.method,
          headers: upstreamHeaders,
        });
      }

      const response = await fetch(upstreamRequest, {
        signal: AbortSignal.timeout(upstreamTimeoutMs),
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
// trigger redeploy 2026-06-13T18:00:00+08:00
