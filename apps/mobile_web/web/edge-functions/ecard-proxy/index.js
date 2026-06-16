// OneGZUS ecard proxy - EdgeOne Makers edge function.

const DEFAULT_ECARD_BASE = 'https://ecarduser.gzus.edu.cn';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0) AppleWebKit/605.1.15 ' +
  'Mobile/15E148 MicroMessenger/8.0.38';
const ROOM_IMPL_TYPES = ['CGCOMMON1111', 'CGCOMMON2222', 'CGCOMMON3333'];
const CORS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Access-Control-Allow-Origin': '*',
};
const CORS_PREFLIGHT = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

let tokenCache = { token: null, unionid: null, ts: 0 };

function envOf(context) {
  return context.env || {};
}

function json(data, status) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: CORS,
  });
}

function md5(input) {
  const bytes = new TextEncoder().encode(input);
  const words = [];
  let i;
  for (i = 0; i < bytes.length; i++) {
    words[i >> 2] |= bytes[i] << ((i % 4) * 8);
  }
  words[bytes.length >> 2] |= 128 << ((bytes.length % 4) * 8);
  words[(((bytes.length + 8) >> 6) << 4) + 14] = bytes.length * 8;

  let a = 1732584193;
  let b = -271733879;
  let c = -1732584194;
  let d = 271733878;
  for (i = 0; i < words.length; i += 16) {
    const oa = a;
    const ob = b;
    const oc = c;
    const od = d;
    a = ff(a, b, c, d, words[i], 7, -680876936);
    d = ff(d, a, b, c, words[i + 1], 12, -389564586);
    c = ff(c, d, a, b, words[i + 2], 17, 606105819);
    b = ff(b, c, d, a, words[i + 3], 22, -1044525330);
    a = ff(a, b, c, d, words[i + 4], 7, -176418897);
    d = ff(d, a, b, c, words[i + 5], 12, 1200080426);
    c = ff(c, d, a, b, words[i + 6], 17, -1473231341);
    b = ff(b, c, d, a, words[i + 7], 22, -45705983);
    a = ff(a, b, c, d, words[i + 8], 7, 1770035416);
    d = ff(d, a, b, c, words[i + 9], 12, -1958414417);
    c = ff(c, d, a, b, words[i + 10], 17, -42063);
    b = ff(b, c, d, a, words[i + 11], 22, -1990404162);
    a = ff(a, b, c, d, words[i + 12], 7, 1804603682);
    d = ff(d, a, b, c, words[i + 13], 12, -40341101);
    c = ff(c, d, a, b, words[i + 14], 17, -1502002290);
    b = ff(b, c, d, a, words[i + 15], 22, 1236535329);
    a = gg(a, b, c, d, words[i + 1], 5, -165796510);
    d = gg(d, a, b, c, words[i + 6], 9, -1069501632);
    c = gg(c, d, a, b, words[i + 11], 14, 643717713);
    b = gg(b, c, d, a, words[i], 20, -373897302);
    a = gg(a, b, c, d, words[i + 5], 5, -701558691);
    d = gg(d, a, b, c, words[i + 10], 9, 38016083);
    c = gg(c, d, a, b, words[i + 15], 14, -660478335);
    b = gg(b, c, d, a, words[i + 4], 20, -405537848);
    a = gg(a, b, c, d, words[i + 9], 5, 568446438);
    d = gg(d, a, b, c, words[i + 14], 9, -1019803690);
    c = gg(c, d, a, b, words[i + 3], 14, -187363961);
    b = gg(b, c, d, a, words[i + 8], 20, 1163531501);
    a = gg(a, b, c, d, words[i + 13], 5, -1444681467);
    d = gg(d, a, b, c, words[i + 2], 9, -51403784);
    c = gg(c, d, a, b, words[i + 7], 14, 1735328473);
    b = gg(b, c, d, a, words[i + 12], 20, -1926607734);
    a = hh(a, b, c, d, words[i + 5], 4, -378558);
    d = hh(d, a, b, c, words[i + 8], 11, -2022574463);
    c = hh(c, d, a, b, words[i + 11], 16, 1839030562);
    b = hh(b, c, d, a, words[i + 14], 23, -35309556);
    a = hh(a, b, c, d, words[i + 1], 4, -1530992060);
    d = hh(d, a, b, c, words[i + 4], 11, 1272893353);
    c = hh(c, d, a, b, words[i + 7], 16, -155497632);
    b = hh(b, c, d, a, words[i + 10], 23, -1094730640);
    a = hh(a, b, c, d, words[i + 13], 4, 681279174);
    d = hh(d, a, b, c, words[i], 11, -358537222);
    c = hh(c, d, a, b, words[i + 3], 16, -722521979);
    b = hh(b, c, d, a, words[i + 6], 23, 76029189);
    a = hh(a, b, c, d, words[i + 9], 4, -640364487);
    d = hh(d, a, b, c, words[i + 12], 11, -421815835);
    c = hh(c, d, a, b, words[i + 15], 16, 530742520);
    b = hh(b, c, d, a, words[i + 2], 23, -995338651);
    a = ii(a, b, c, d, words[i], 6, -198630844);
    d = ii(d, a, b, c, words[i + 7], 10, 1126891415);
    c = ii(c, d, a, b, words[i + 14], 15, -1416354905);
    b = ii(b, c, d, a, words[i + 5], 21, -57434055);
    a = ii(a, b, c, d, words[i + 12], 6, 1700485571);
    d = ii(d, a, b, c, words[i + 3], 10, -1894986606);
    c = ii(c, d, a, b, words[i + 10], 15, -1051523);
    b = ii(b, c, d, a, words[i + 1], 21, -2054922799);
    a = ii(a, b, c, d, words[i + 8], 6, 1873313359);
    d = ii(d, a, b, c, words[i + 15], 10, -30611744);
    c = ii(c, d, a, b, words[i + 6], 15, -1560198380);
    b = ii(b, c, d, a, words[i + 13], 21, 1309151649);
    a = ii(a, b, c, d, words[i + 4], 6, -145523070);
    d = ii(d, a, b, c, words[i + 11], 10, -1120210379);
    c = ii(c, d, a, b, words[i + 2], 15, 718787259);
    b = ii(b, c, d, a, words[i + 9], 21, -343485551);
    a = add(a, oa);
    b = add(b, ob);
    c = add(c, oc);
    d = add(d, od);
  }
  return hex(a) + hex(b) + hex(c) + hex(d);
}

function cmn(q, a, b, x, s, t) {
  return add(rol(add(add(a, q), add(x, t)), s), b);
}
function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
function rol(n, c) { return (n << c) | (n >>> (32 - c)); }
function add(x, y) {
  const low = (x & 0xffff) + (y & 0xffff);
  return (((x >> 16) + (y >> 16) + (low >> 16)) << 16) | (low & 0xffff);
}
function hex(n) {
  const h = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 4; i++) {
    out += h.charAt((n >> (i * 8 + 4)) & 15) + h.charAt((n >> (i * 8)) & 15);
  }
  return out;
}

function requireConfig(env) {
  const config = {
    baseUrl: (env.ECARD_BASE_URL || DEFAULT_ECARD_BASE).replace(/\/$/, ''),
    openid: env.ECARD_OPENID || '',
    secret: env.ECARD_SECRET || '',
    proxyToken: env.ECARD_PROXY_TOKEN || '',
  };
  if (!config.openid || !config.secret || !config.proxyToken) {
    return { error: 'ecard proxy env not configured', config };
  }
  return { config };
}

function verifyRequest(url, env) {
  const { error, config } = requireConfig(env);
  if (error) return { response: json({ error }, 503) };
  if (url.searchParams.get('eo_token') !== config.proxyToken) {
    return { response: json({ error: 'unauthorized' }, 401) };
  }
  return { config };
}

function sign(params, secret) {
  const keys = Object.keys(params).filter((key) => key !== 'token' && key !== 'sign').sort();
  const raw = keys.map((key) => `${key}=${params[key]}`).join('&') + `&${secret}`;
  return md5(raw).toUpperCase();
}

function encodeForm(data) {
  return Object.keys(data)
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(data[key])}`)
    .join('&');
}

async function login(config) {
  if (tokenCache.token && Date.now() - tokenCache.ts < 3600000) return true;
  const payload = {
    from: 'wxminiprogram',
    isWxEnterpriseXcx: 'false',
    wxRequest: 'wxRequest',
    openid: config.openid,
  };
  payload.sign = sign(payload, config.secret);
  const response = await fetch(`${config.baseUrl}/user/routine/routine-login`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'User-Agent': UA,
    },
    body: encodeForm(payload),
  });
  const data = await response.json();
  if (data.code === 200 && data.token) {
    tokenCache = { token: data.token, unionid: data.unionid || '', ts: Date.now() };
    return true;
  }
  tokenCache = { token: null, unionid: null, ts: 0 };
  return false;
}

async function post(config, path, params) {
  await login(config);
  const payload = { ...(params || {}) };
  payload.from = 'wxminiprogram';
  payload.isWxEnterpriseXcx = 'false';
  payload.wxRequest = 'wxRequest';
  payload.openid = config.openid;
  if (tokenCache.unionid) payload.unionid = tokenCache.unionid;
  if (tokenCache.token) payload.token = tokenCache.token;
  payload.sign = sign(payload, config.secret);
  const response = await fetch(`${config.baseUrl}/${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'User-Agent': UA,
    },
    body: encodeForm(payload),
  });
  return response.json();
}

function isOk(data) {
  return data && (data.ret === true || data.code === 0 || data.code === 200 || data.resCode === 0 || data.resCode === '0');
}

function roomDisplayName(room) {
  const roomName = String(room.room || '').replace(/#/g, '-') || String(room.roomNum || '');
  return [room.schoolArea || '', room.building || '', roomName].filter(Boolean).join(' ');
}

function publicRoom(room, implType) {
  const id = [
    room.implType || implType,
    room.schoolAreaNo || '',
    room.buildingNo || '',
    room.roomNum || '',
  ].join('|');
  return {
    id,
    schoolArea: String(room.schoolArea || ''),
    building: String(room.building || ''),
    room: String(room.room || '').replace(/#/g, '-') || String(room.roomNum || ''),
    displayName: roomDisplayName(room),
  };
}

async function getRooms(config, query, limit) {
  const rooms = [];
  const seen = new Set();
  const keyword = String(query || '').trim().toLowerCase();
  const max = Math.max(1, Math.min(Number(limit) || 100, 100));
  for (const implType of ROOM_IMPL_TYPES) {
    const data = await post(config, 'powerfee/getRoomInfo', { implType });
    const obj = data.obj || [];
    const list = Array.isArray(obj) ? obj : [obj];
    for (const room of list) {
      if (!room || typeof room !== 'object') continue;
      const item = publicRoom(room, implType);
      if (seen.has(item.id) || item.id.includes('||')) continue;
      seen.add(item.id);
      if (
        keyword &&
        !item.displayName.toLowerCase().includes(keyword) &&
        !item.building.toLowerCase().includes(keyword) &&
        !item.room.toLowerCase().includes(keyword) &&
        !item.schoolArea.toLowerCase().includes(keyword)
      ) {
        continue;
      }
      rooms.push(item);
      if (rooms.length >= max) {
        return rooms;
      }
    }
  }
  return rooms;
}

function formatValue(value, unit) {
  if (value === null || value === undefined || String(value) === '' || String(value) === 'null') {
    return null;
  }
  return `${value} ${unit}`.trim();
}

async function getHotWaterBalance(config, studentId) {
  if (!studentId) return null;
  try {
    const data = await post(config, 'waterfee/memberInfo', {
      sno: studentId,
      implType: 'MINGHANBLUETOOTH',
    });
    if (!isOk(data)) return null;
    return (data.obj || {}).balance ?? null;
  } catch (_) {
    return null;
  }
}

async function getBalance(config, roomId, studentId) {
  const parts = String(roomId || '').split('|');
  if (parts.length !== 4 || parts.some((part) => part === '')) {
    return { error: 'need roomId=implType|areaNo|buildingNo|roomNum' };
  }
  const data = await post(config, 'powerfee/getBalance', {
    implType: parts[0],
    schoolAreaNo: parts[1],
    buildingNo: parts[2],
    roomNum: parts[3],
  });
  if (!isOk(data)) {
    return { error: data.msg || 'getBalance failed' };
  }
  const obj = data.obj || {};
  const hotWaterBalance = await getHotWaterBalance(config, studentId);
  return {
    powerBalance: obj.powerBalance,
    powerText: obj.formatPowerBalanceStr || formatValue(obj.powerBalance, obj.du || '度'),
    coldWaterBalance: obj.waterBalance,
    coldWaterText: obj.formatWaterBalanceStr || formatValue(obj.waterBalance, obj.dun || '吨'),
    hotWaterBalance,
    hotWaterText: obj.formatHotWaterBalanceStr || formatValue(hotWaterBalance, '元'),
  };
}

function publicConsumptionItem(item, unit) {
  if (!item || typeof item !== 'object') {
    return { title: String(item), amount: '', time: '' };
  }
  const dailyUsed = String(item.dailyUsed || '');
  const leftUsed = String(item.leftUsed || '');
  const leftFree = String(item.leftFree || '');
  const details = [];
  if (leftUsed) details.push(`剩余 ${leftUsed} ${unit}`.trim());
  if (leftFree) details.push(`免费额 ${leftFree} ${unit}`.trim());
  return {
    title: details.join(' · ') || '电费日用',
    amount: dailyUsed ? `${dailyUsed} ${unit}`.trim() : '',
    time: String(item.dateTime || ''),
  };
}

async function getConsumption(config, roomId, month) {
  const parts = String(roomId || '').split('|');
  if (parts.length !== 4 || parts.some((part) => part === '')) {
    return { error: 'need roomId=implType|areaNo|buildingNo|roomNum' };
  }
  const data = await post(config, 'powerfee/getDailyDetails', {
    roomNum: parts[3],
    lastDate: month || '',
    type: '',
    implType: parts[0],
    schoolAreaNo: parts[1],
    pageNum: '1',
    pageSize: '31',
  });
  if (!isOk(data)) {
    return { error: data.msg || 'getDailyDetails failed' };
  }
  const obj = data.obj || {};
  const items = Array.isArray(obj.dailyDetailsInfos) ? obj.dailyDetailsInfos : [];
  const unit = String(obj.dailyUsedUnit || '度');
  return {
    status: 'ok',
    items: items.map((item) => publicConsumptionItem(item, unit)),
  };
}

function actionFromUrl(url) {
  const match = url.pathname.match(/\/ecard-proxy\/?([^/]*)/);
  return (url.searchParams.get('action') || (match && match[1]) || 'rooms').trim() || 'rooms';
}

export async function onRequestGet(context) {
  const url = new URL(context.request.url);
  const { response, config } = verifyRequest(url, envOf(context));
  if (response) return response;

  try {
    const action = actionFromUrl(url);
    let data;
    if (action === 'health') {
      data = { status: 'ok', token: !!tokenCache.token };
    } else if (action === 'rooms') {
      data = await getRooms(
        config,
        url.searchParams.get('q') || '',
        parseInt(url.searchParams.get('limit') || '100', 10),
      );
    } else if (action === 'balance') {
      data = await getBalance(
        config,
        url.searchParams.get('roomId') || '',
        url.searchParams.get('studentId') || '',
      );
    } else if (action === 'consumption') {
      data = await getConsumption(
        config,
        url.searchParams.get('roomId') || '',
        url.searchParams.get('month') || '',
      );
    } else {
      data = { error: `unknown: ${action}` };
    }
    return json(data, data.error ? 400 : 200);
  } catch (error) {
    return json({ error: error.message || 'runtime error' }, 502);
  }
}

export function onRequestOptions() {
  return new Response(null, { status: 204, headers: CORS_PREFLIGHT });
}
