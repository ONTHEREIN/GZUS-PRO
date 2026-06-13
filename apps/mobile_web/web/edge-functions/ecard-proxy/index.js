// OneGZUS ecard proxy — EdgeOne Pages edge function
// Vercel → EdgeOne (China IP) → ecarduser.gzus.edu.cn

var ECARD = 'https://ecarduser.gzus.edu.cn';
var SECRET = 'greatge';
var OPENID = 'o6gXt5YdtSc-15PgJg0KqAXZytRc';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.38';
var CORS = { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' };
var CORS_PREFLIGHT = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' };
var tokenCache = { token: null, unionid: null, ts: 0 };

// Verified MD5 (strict-mode safe: all vars explicitly declared)
function md5(s) {
  var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
  var x = [], i, j, oa, ob, oc, od;
  for (i = 0; i < s.length; i++) x[i >> 2] |= (s.charCodeAt(i) & 255) << ((i % 4) * 8);
  x[s.length >> 2] |= 128 << ((s.length % 4) * 8);
  x[((s.length + 8) >> 6 << 4) + 14] = s.length * 8;
  for (i = 0; i < x.length; i += 16) {
    oa = a; ob = b; oc = c; od = d;
    a = ff(a, b, c, d, x[i], 7, -680876936); d = ff(d, a, b, c, x[i + 1], 12, -389564586); c = ff(c, d, a, b, x[i + 2], 17, 606105819); b = ff(b, c, d, a, x[i + 3], 22, -1044525330);
    a = ff(a, b, c, d, x[i + 4], 7, -176418897); d = ff(d, a, b, c, x[i + 5], 12, 1200080426); c = ff(c, d, a, b, x[i + 6], 17, -1473231341); b = ff(b, c, d, a, x[i + 7], 22, -45705983);
    a = ff(a, b, c, d, x[i + 8], 7, 1770035416); d = ff(d, a, b, c, x[i + 9], 12, -1958414417); c = ff(c, d, a, b, x[i + 10], 17, -42063); b = ff(b, c, d, a, x[i + 11], 22, -1990404162);
    a = ff(a, b, c, d, x[i + 12], 7, 1804603682); d = ff(d, a, b, c, x[i + 13], 12, -40341101); c = ff(c, d, a, b, x[i + 14], 17, -1502002290); b = ff(b, c, d, a, x[i + 15], 22, 1236535329);
    a = gg(a, b, c, d, x[i + 1], 5, -165796510); d = gg(d, a, b, c, x[i + 6], 9, -1069501632); c = gg(c, d, a, b, x[i + 11], 14, 643717713); b = gg(b, c, d, a, x[i], 20, -373897302);
    a = gg(a, b, c, d, x[i + 5], 5, -701558691); d = gg(d, a, b, c, x[i + 10], 9, 38016083); c = gg(c, d, a, b, x[i + 15], 14, -660478335); b = gg(b, c, d, a, x[i + 4], 20, -405537848);
    a = gg(a, b, c, d, x[i + 9], 5, 568446438); d = gg(d, a, b, c, x[i + 14], 9, -1019803690); c = gg(c, d, a, b, x[i + 3], 14, -187363961); b = gg(b, c, d, a, x[i + 8], 20, 1163531501);
    a = gg(a, b, c, d, x[i + 13], 5, -1444681467); d = gg(d, a, b, c, x[i + 2], 9, -51403784); c = gg(c, d, a, b, x[i + 7], 14, 1735328473); b = gg(b, c, d, a, x[i + 12], 20, -1926607734);
    a = hh(a, b, c, d, x[i + 5], 4, -378558); d = hh(d, a, b, c, x[i + 8], 11, -2022574463); c = hh(c, d, a, b, x[i + 11], 16, 1839030562); b = hh(b, c, d, a, x[i + 14], 23, -35309556);
    a = hh(a, b, c, d, x[i + 1], 4, -1530992060); d = hh(d, a, b, c, x[i + 4], 11, 1272893353); c = hh(c, d, a, b, x[i + 7], 16, -155497632); b = hh(b, c, d, a, x[i + 10], 23, -1094730640);
    a = hh(a, b, c, d, x[i + 13], 4, 681279174); d = hh(d, a, b, c, x[i], 11, -358537222); c = hh(c, d, a, b, x[i + 3], 16, -722521979); b = hh(b, c, d, a, x[i + 6], 23, 76029189);
    a = hh(a, b, c, d, x[i + 9], 4, -640364487); d = hh(d, a, b, c, x[i + 12], 11, -421815835); c = hh(c, d, a, b, x[i + 15], 16, 530742520); b = hh(b, c, d, a, x[i + 2], 23, -995338651);
    a = ii(a, b, c, d, x[i], 6, -198630844); d = ii(d, a, b, c, x[i + 7], 10, 1126891415); c = ii(c, d, a, b, x[i + 14], 15, -1416354905); b = ii(b, c, d, a, x[i + 5], 21, -57434055);
    a = ii(a, b, c, d, x[i + 12], 6, 1700485571); d = ii(d, a, b, c, x[i + 3], 10, -1894986606); c = ii(c, d, a, b, x[i + 10], 15, -1051523); b = ii(b, c, d, a, x[i + 1], 21, -2054922799);
    a = ii(a, b, c, d, x[i + 8], 6, 1873313359); d = ii(d, a, b, c, x[i + 15], 10, -30611744); c = ii(c, d, a, b, x[i + 6], 15, -1560198380); b = ii(b, c, d, a, x[i + 13], 21, 1309151649);
    a = ii(a, b, c, d, x[i + 4], 6, -145523070); d = ii(d, a, b, c, x[i + 11], 10, -1120210379); c = ii(c, d, a, b, x[i + 2], 15, 718787259); b = ii(b, c, d, a, x[i + 9], 21, -343485551);
    a = add(a, oa); b = add(b, ob); c = add(c, oc); d = add(d, od);
  }
  return hex(a) + hex(b) + hex(c) + hex(d);
}
function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
function cmn(q, a, b, x, s, t) { return add(rol(add(add(a, q), add(x, t)), s), b); }
function rol(n, c) { return (n << c) | (n >>> (32 - c)); }
function add(x, y) { var l = (x & 0xFFFF) + (y & 0xFFFF); return (((x >> 16) + (y >> 16) + (l >> 16)) << 16) | (l & 0xFFFF); }
function hex(n) { var h = '0123456789abcdef', r = '', i; for (i = 0; i < 4; i++) r += h.charAt((n >> (i * 8 + 4)) & 15) + h.charAt((n >> (i * 8)) & 15); return r; }

function sign(params) {
  var keys = Object.keys(params).filter(function (k) { return k !== 'token' && k !== 'sign'; }).sort();
  return keys.map(function (k) { return k + '=' + params[k]; }).join('&') + '&' + SECRET;
}

function encodeForm(data) {
  return Object.keys(data).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(data[k]); }).join('&');
}

async function login() {
  var p = { from: 'wxminiprogram', isWxEnterpriseXcx: 'false', wxRequest: 'wxRequest', openid: OPENID };
  p.sign = md5(sign(p)).toUpperCase();
  var r = await fetch(ECARD + '/user/routine/routine-login', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA }, body: encodeForm(p),
  });
  var d = await r.json();
  if (d.code === 200 && d.token) { tokenCache = { token: d.token, unionid: d.unionid || '', ts: Date.now() }; return true; }
  return false;
}

async function post(path, params) {
  params = params || {};
  if (!tokenCache.token || Date.now() - tokenCache.ts > 3600000) await login();
  var p = {};
  var k;
  for (k in params) p[k] = params[k];
  p.from = 'wxminiprogram'; p.isWxEnterpriseXcx = 'false'; p.wxRequest = 'wxRequest'; p.openid = OPENID;
  if (tokenCache.unionid) p.unionid = tokenCache.unionid;
  if (tokenCache.token) p.token = tokenCache.token;
  p.sign = md5(sign(p)).toUpperCase();
  var r = await fetch(ECARD + '/' + path, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA }, body: encodeForm(p),
  });
  return r.json();
}

async function getRooms(query, limit) {
  var rooms = [], seen = {};
  var types = ['CGCOMMON1111', 'CGCOMMON2222', 'CGCOMMON3333'];
  for (var t = 0; t < types.length; t++) {
    var d = await post('powerfee/getRoomInfo', { implType: types[t] });
    var obj = d.obj || [];
    if (obj && !(obj instanceof Array)) obj = [obj];
    for (var r = 0; r < obj.length; r++) {
      var room = obj[r];
      if (!room || typeof room !== 'object') continue;
      var rid = (room.implType || types[t]) + '|' + (room.schoolAreaNo || '') + '|' + (room.buildingNo || '') + '|' + (room.roomNum || '');
      if (seen[rid] || rid.indexOf('||') >= 0) continue;
      seen[rid] = true;
      var dn = [(room.schoolArea || ''), (room.building || ''), (room.room || room.roomNum || '').replace(/#/g, '-')].filter(function (x) { return x; }).join(' ');
      rooms.push({ id: rid, displayName: dn, schoolArea: String(room.schoolArea || ''), building: String(room.building || ''), room: String(room.room || '').replace(/#/g, '-') });
    }
  }
  rooms.sort(function (a, b) { return a.displayName.localeCompare(b.displayName); });
  if (query) {
    var q = query.toLowerCase();
    rooms = rooms.filter(function (r) { return r.displayName.toLowerCase().indexOf(q) >= 0 || r.building.toLowerCase().indexOf(q) >= 0 || r.room.toLowerCase().indexOf(q) >= 0; });
  }
  return rooms.slice(0, limit || 100);
}

async function getBalance(roomId) {
  var parts = roomId.split('|');
  if (parts.length !== 4) return { error: 'need roomId=implType|areaNo|buildingNo|roomNum' };
  var d = await post('powerfee/getBalance', { implType: parts[0], schoolAreaNo: parts[1], buildingNo: parts[2], roomNum: parts[3] });
  var o = d.obj || {};
  return { powerBalance: o.powerBalance, waterBalance: o.waterBalance, hotWaterBalance: o.hotWaterBalance,
    powerText: o.formatPowerBalanceStr || '', waterText: o.formatWaterBalanceStr || '', hotWaterText: o.formatHotWaterBalanceStr || '' };
}

export async function onRequestGet(context) {
  var url = new URL(context.request.url);
  var p = {};
  url.searchParams.forEach(function (v, k) { p[k] = v; });
  var action = p.action || url.pathname.replace(/\/ecard-proxy\/?/, '') || 'rooms';
  try {
    var data;
    if (action === 'rooms')
      data = await getRooms(p.q || '', parseInt(p.limit || '100'));
    else if (action === 'balance')
      data = await getBalance(p.roomId || '');
    else if (action === 'health')
      data = { status: 'ok', token: !!tokenCache.token };
    else
      data = { error: 'unknown: ' + action };
    return new Response(JSON.stringify(data), { status: data.error ? 400 : 200, headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message || 'runtime error' }), { status: 502, headers: CORS });
  }
}

export function onRequestOptions() {
  return new Response(null, { status: 204, headers: CORS_PREFLIGHT });
}
