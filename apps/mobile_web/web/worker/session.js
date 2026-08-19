// 会话存储（内存 Map + Cloudflare KV 回退）+ 学术数据缓存（自 _worker.js 拆分）。
// 依赖：sleep（./crypto.js）。
// 可变 Map（localSessions/localAcademicCache/localAcademicInFlight）作为
// ESM live binding export，供 fetch handler 直接读取（绑定不变、内容可变）。
import { sleep } from './crypto.js';

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


export {
  lookupSessionCookies,
  createPersistentSession,
  getLocalSession,
  defaultAcademicPeriod,
  loadAcademicCache,
  saveAcademicCache,
  localSessions,
  localAcademicCache,
  localAcademicInFlight,
};

