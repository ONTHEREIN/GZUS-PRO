// 共享配置常量（自 _worker.js 拆分）。
// CAS/JWXT/EHALL 端点与各接口超时阈值，login.js 与 _worker.js 共同引用。

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
const DASHBOARD_DIRECT_TIMEOUT_MS = 9000;
// 学分接口响应慢：专用更短超时，让 Worker 在 Flutter 等待前返回（缓存或错误）
const CREDITS_DIRECT_TIMEOUT_MS = 4500;
const DASHBOARD_BACKEND_TIMEOUT_MS = 12000;
const DASHBOARD_MODULE_TIMEOUT_MS = 13000;
const DASHBOARD_TOTAL_TIMEOUT_MS = 20000;

export {
  CAS_BASE,
  JWXT_ORIGIN,
  JWXT_LEGACY_ORIGIN,
  JWXT_SERVICE_URL,
  JWXT_LEGACY_SERVICE_URL,
  SERVICE_URL,
  JWXT_SERVICE_URLS,
  EHALL_URL,
  EHALL_CAS_SERVICE_URL,
  JWXT_BASE,
  JWXT_REFERER,
  DASHBOARD_DIRECT_TIMEOUT_MS,
  CREDITS_DIRECT_TIMEOUT_MS,
  DASHBOARD_BACKEND_TIMEOUT_MS,
  DASHBOARD_MODULE_TIMEOUT_MS,
  DASHBOARD_TOTAL_TIMEOUT_MS,
};

