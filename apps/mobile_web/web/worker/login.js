// CAS SSO 登录流程（自 _worker.js 拆分）。
// 依赖：config.js（端点常量）、crypto.js（RSA/验证码/凭据）、http.js（带 cookie 请求）。
// 仅导出 casAutoLogin 供 fetch handler 的 /auth/auto-login 与 /auth/relogin 调用。
import {
  CAS_BASE,
  JWXT_ORIGIN,
  JWXT_LEGACY_ORIGIN,
  JWXT_SERVICE_URL,
  JWXT_SERVICE_URLS,
  SERVICE_URL,
  EHALL_URL,
  EHALL_CAS_SERVICE_URL,
  JWXT_BASE,
  JWXT_REFERER,
} from './config.js';
import {
  rsaEncrypt,
  solveArithmeticCaptcha,
  base64ToUint8Array,
  uint8ArrayToBase64,
  sleep,
  encryptCredentials,
  MAX_CAPTCHA_RETRIES,
} from './crypto.js';
import {
  fetchWithCookies,
  fetchGbkText,
  vercelOrigin,
} from './http.js';

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

export { casAutoLogin };

