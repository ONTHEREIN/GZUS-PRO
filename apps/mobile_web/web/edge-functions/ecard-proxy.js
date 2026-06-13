// OneGZUS ecard proxy on EdgeOne Pages
// Vercel → EdgeOne (China IP) → ecarduser.gzus.edu.cn
const ECARD = 'https://ecarduser.gzus.edu.cn';
const SECRET = 'greatge';
const OPENID = 'o6gXt5YdtSc-15PgJg0KqAXZytRc';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.38';

let tokenCache = { token: null, unionid: null, ts: 0 };

// Pure JS MD5 (Web Crypto doesn't support MD5, verified against Node.js crypto)
function md5(s){var chrsz=8;function safe_add(x,y){var l=(x&0xFFFF)+(y&0xFFFF);var m=(x>>16)+(y>>16)+(l>>16);return(m<<16)|(l&0xFFFF)}function bit_rol(n,c){return(n<<c)|(n>>>(32-c))}function str2binl(str){var b=Array();var m=(1<<chrsz)-1;for(var i=0;i<str.length*chrsz;i+=chrsz)b[i>>5]|=(str.charCodeAt(i/chrsz)&m)<<(i%32);return b}function binl2hex(b){var t=[];for(var i=0;i<b.length*4;i++)t.push('0123456789abcdef'.charAt((b[i>>2]>>((i%4)*8+4))&0xF),'0123456789abcdef'.charAt((b[i>>2]>>((i%4)*8))&0xF));return t.join('')}function cmn(q,a,b,x,s,t){return safe_add(bit_rol(safe_add(safe_add(a,q),safe_add(x,t)),s),b)}function ff(a,b,c,d,x,s,t){return cmn((b&c)|((~b)&d),a,b,x,s,t)}function gg(a,b,c,d,x,s,t){return cmn((b&d)|(c&(~d)),a,b,x,s,t)}function hh(a,b,c,d,x,s,t){return cmn(b^c^d,a,b,x,s,t)}function ii(a,b,c,d,x,s,t){return cmn(c^(b|(~d)),a,b,x,s,t)}var x=str2binl(s);var len=s.length*chrsz;x[len>>5]|=0x80<<((len)%32);x[(((len+64)>>>9)<<4)+14]=len;var a=1732584193,b=-271733879,c=-1732584194,d=271733878;for(var i=0;i<x.length;i+=16){var oa=a,ob=b,oc=c,od=d;a=ff(a,b,c,d,x[i+0],7,-680876936);d=ff(d,a,b,c,x[i+1],12,-389564586);c=ff(c,d,a,b,x[i+2],17,606105819);b=ff(b,c,d,a,x[i+3],22,-1044525330);a=ff(a,b,c,d,x[i+4],7,-176418897);d=ff(d,a,b,c,x[i+5],12,1200080426);c=ff(c,d,a,b,x[i+6],17,-1473231341);b=ff(b,c,d,a,x[i+7],22,-45705983);a=ff(a,b,c,d,x[i+8],7,1770035416);d=ff(d,a,b,c,x[i+9],12,-1958414417);c=ff(c,d,a,b,x[i+10],17,-42063);b=ff(b,c,d,a,x[i+11],22,-1990404162);a=ff(a,b,c,d,x[i+12],7,1804603682);d=ff(d,a,b,c,x[i+13],12,-40341101);c=ff(c,d,a,b,x[i+14],17,-1502002290);b=ff(b,c,d,a,x[i+15],22,1236535329);a=gg(a,b,c,d,x[i+1],5,-165796510);d=gg(d,a,b,c,x[i+6],9,-1069501632);c=gg(c,d,a,b,x[i+11],14,643717713);b=gg(b,c,d,a,x[i+0],20,-373897302);a=gg(a,b,c,d,x[i+5],5,-701558691);d=gg(d,a,b,c,x[i+10],9,38016083);c=gg(c,d,a,b,x[i+15],14,-660478335);b=gg(b,c,d,a,x[i+4],20,-405537848);a=gg(a,b,c,d,x[i+9],5,568446438);d=gg(d,a,b,c,x[i+14],9,-1019803690);c=gg(c,d,a,b,x[i+3],14,-187363961);b=gg(b,c,d,a,x[i+8],20,1163531501);a=gg(a,b,c,d,x[i+13],5,-1444681467);d=gg(d,a,b,c,x[i+2],9,-51403784);c=gg(c,d,a,b,x[i+7],14,1735328473);b=gg(b,c,d,a,x[i+12],20,-1926607734);a=hh(a,b,c,d,x[i+5],4,-378558);d=hh(d,a,b,c,x[i+8],11,-2022574463);c=hh(c,d,a,b,x[i+11],16,1839030562);b=hh(b,c,d,a,x[i+14],23,-35309556);a=hh(a,b,c,d,x[i+1],4,-1530992060);d=hh(d,a,b,c,x[i+4],11,1272893353);c=hh(c,d,a,b,x[i+7],16,-155497632);b=hh(b,c,d,a,x[i+10],23,-1094730640);a=hh(a,b,c,d,x[i+13],4,681279174);d=hh(d,a,b,c,x[i+0],11,-358537222);c=hh(c,d,a,b,x[i+3],16,-722521979);b=hh(b,c,d,a,x[i+6],23,76029189);a=hh(a,b,c,d,x[i+9],4,-640364487);d=hh(d,a,b,c,x[i+12],11,-421815835);c=hh(c,d,a,b,x[i+15],16,530742520);b=hh(b,c,d,a,x[i+2],23,-995338651);a=ii(a,b,c,d,x[i+0],6,-198630844);d=ii(d,a,b,c,x[i+7],10,1126891415);c=ii(c,d,a,b,x[i+14],15,-1416354905);b=ii(b,c,d,a,x[i+5],21,-57434055);a=ii(a,b,c,d,x[i+12],6,1700485571);d=ii(d,a,b,c,x[i+3],10,-1894986606);c=ii(c,d,a,b,x[i+10],15,-1051523);b=ii(b,c,d,a,x[i+1],21,-2054922799);a=ii(a,b,c,d,x[i+8],6,1873313359);d=ii(d,a,b,c,x[i+15],10,-30611744);c=ii(c,d,a,b,x[i+6],15,-1560198380);b=ii(b,c,d,a,x[i+13],21,1309151649);a=ii(a,b,c,d,x[i+4],6,-145523070);d=ii(d,a,b,c,x[i+11],10,-1120210379);c=ii(c,d,a,b,x[i+2],15,718787259);b=ii(b,c,d,a,x[i+9],21,-343485551);a=safe_add(a,oa);b=safe_add(b,ob);c=safe_add(c,oc);d=safe_add(d,od)}return binl2hex([a,b,c,d])}

function sign(params) {
  const keys = Object.keys(params).filter(k => k !== 'token' && k !== 'sign').sort();
  return keys.map(k => `${k}=${params[k]}`).join('&') + '&' + SECRET;
}

async function login() {
  const p = { from: 'wxminiprogram', isWxEnterpriseXcx: 'false', wxRequest: 'wxRequest', openid: OPENID };
  p.sign = md5(sign(p)).toUpperCase();

  const r = await fetch(`${ECARD}/user/routine/routine-login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA },
    body: new URLSearchParams(p).toString(),
  });
  const d = await r.json();
  if (d.code === 200 && d.token) {
    tokenCache = { token: d.token, unionid: d.unionid || '', ts: Date.now() };
    return true;
  }
  return false;
}

async function post(path, params = {}) {
  if (!tokenCache.token || Date.now() - tokenCache.ts > 3600000) await login();
  const p = { ...params, from: 'wxminiprogram', isWxEnterpriseXcx: 'false', wxRequest: 'wxRequest', openid: OPENID };
  if (tokenCache.unionid) p.unionid = tokenCache.unionid;
  if (tokenCache.token) p.token = tokenCache.token;
  p.sign = md5(sign(p)).toUpperCase();

  const r = await fetch(`${ECARD}/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA },
    body: new URLSearchParams(p).toString(),
  });
  return r.json();
}

export async function onRequestGet(context) {
  const url = new URL(context.request.url);
  const p = Object.fromEntries(url.searchParams);
  const action = p.action || url.pathname.replace('/ecard-proxy/', '') || 'rooms';

  try {
    let data;
    if (action === 'rooms') {
      const rooms = []; const seen = new Set();
      for (const impl of ['CGCOMMON1111', 'CGCOMMON2222', 'CGCOMMON3333']) {
        const d = await post('powerfee/getRoomInfo', { implType: impl });
        for (const room of (d.obj || [])) {
          if (!room || typeof room !== 'object') continue;
          const rid = `${room.implType || impl}|${room.schoolAreaNo || ''}|${room.buildingNo || ''}|${room.roomNum || ''}`;
          if (seen.has(rid) || rid.includes('||')) continue;
          seen.add(rid);
          rooms.push({
            id: rid,
            displayName: `${room.schoolArea || ''} ${room.building || ''} ${(room.room || room.roomNum || '').replace('#', '-')}`.trim(),
            schoolArea: String(room.schoolArea || ''),
            building: String(room.building || ''),
            room: String(room.room || '').replace('#', '-'),
          });
        }
      }
      rooms.sort((a, b) => a.displayName.localeCompare(b.displayName));
      const q = (p.q || '').toLowerCase();
      const limit = parseInt(p.limit || '100');
      data = q ? rooms.filter(r => r.displayName.toLowerCase().includes(q) || r.building.toLowerCase().includes(q) || r.room.toLowerCase().includes(q)).slice(0, limit) : rooms.slice(0, limit);
    } else if (action === 'balance') {
      const parts = (p.roomId || '').split('|');
      if (parts.length !== 4) { data = { error: 'need roomId=implType|areaNo|buildingNo|roomNum' }; }
      else {
        const d = await post('powerfee/getBalance', { implType: parts[0], schoolAreaNo: parts[1], buildingNo: parts[2], roomNum: parts[3] });
        const o = d.obj || {};
        data = { powerBalance: o.powerBalance, waterBalance: o.waterBalance, hotWaterBalance: o.hotWaterBalance, powerText: o.formatPowerBalanceStr || '', waterText: o.formatWaterBalanceStr || '', hotWaterText: o.formatHotWaterBalanceStr || '' };
      }
    } else if (action === 'health') {
      data = { status: 'ok', token: !!tokenCache.token };
    } else {
      data = { error: 'unknown action: ' + action };
    }
    return new Response(JSON.stringify(data), {
      status: data.error ? 400 : 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 502,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' },
  });
}
