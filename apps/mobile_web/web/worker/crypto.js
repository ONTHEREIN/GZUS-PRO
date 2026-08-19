// 密码学 + 验证码 + 编码辅助（自 _worker.js 拆分）。
// 纯函数簇：仅依赖常量与 Web Crypto 全局，无跨模块依赖。
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

export {
  rsaEncrypt,
  solveArithmeticCaptcha,
  md5,
  base64ToUint8Array,
  uint8ArrayToBase64,
  sleep,
  encryptCredentials,
  decryptCredentials,
  MAX_CAPTCHA_RETRIES,
};

