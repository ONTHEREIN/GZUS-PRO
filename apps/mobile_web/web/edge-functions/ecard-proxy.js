// OneGZUS ecard proxy on EdgeOne Pages
// Vercel → EdgeOne (China IP) → ecarduser.gzus.edu.cn
const ECARD = 'https://ecarduser.gzus.edu.cn';
const SECRET = 'greatge';
const OPENID = 'o6gXt5YdtSc-15PgJg0KqAXZytRc';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.38';

let tokenCache = { token: null, unionid: null, ts: 0 };

// Pure JS MD5 (Web Crypto doesn't support MD5)
function md5(s) {function L(k,d){return(k<<d)|(k>>>(32-d))}function K(G,k){var I,d,F,H,x;F=(G&2147483648);H=(k&2147483648);I=(G&1073741824);d=(k&1073741824);x=(G&1073741823)+(k&1073741823);if(I&d)return(x^2147483648^F^H);if(I|d){if(x&1073741824)return(x^3221225472^F^H);else return(x^1073741824^F^H)}else return(x^F^H)}function r(d,F,k){return(d&F)|((~d)&k)}function q(d,F,k){return(d&k)|(F&(~k))}function p(d,F,k){return(d^F^k)}function n(d,F,k){return(F^(d|(~k)))}function u(G,F,aa,Z,k,H,I){G=K(G,K(K(r(F,aa,Z),k),I));return K(L(G,H),F)}function f(G,F,aa,Z,k,H,I){G=K(G,K(K(q(F,aa,Z),k),I));return K(L(G,H),F)}function D(G,F,aa,Z,k,H,I){G=K(G,K(K(p(F,aa,Z),k),I));return K(L(G,H),F)}function t(G,F,aa,Z,k,H,I){G=K(G,K(K(n(F,aa,Z),k),I));return K(L(G,H),F)}function e(G){var Z;var d=G.length;var F=d+8;var k=(F-(F%64))/64;var I=(k+1)*16;var aa=Array(I-1);var H=0;var x=0;while(x<d){Z=(x-(x%4))/4;H=(x%4)*8;aa[Z]=(aa[Z]|(G.charCodeAt(x)<<H));x++}Z=(x-(x%4))/4;H=(x%4)*8;aa[Z]=aa[Z]|(128<<H);aa[I-2]=d<<3;aa[I-1]=d>>>29;return aa}function B(x){var k='',F='',G,d;for(d=0;d<=3;d++){G=(x>>>(d*8))&255;F='0'+G.toString(16);k=k+F.substr(F.length-2,2)}return k}function J(k){k=k.replace(/\r\n/g,'\n');var d='';for(var F=0;F<k.length;F++){var G=k.charCodeAt(F);if(G<128){d+=String.fromCharCode(G)}else if((G>127)&&(G<2048)){d+=String.fromCharCode((G>>6)|192);d+=String.fromCharCode((G&63)|128)}else{d+=String.fromCharCode((G>>12)|224);d+=String.fromCharCode(((G>>6)&63)|128);d+=String.fromCharCode((G&63)|128)}}return d}var C=Array();var P,h,E,v,g,Y,X,W;var O=7,V=12,N=17,M=22;var A=5,U=9,S=14,R=20;var o=4,T=11,Q=16,j=23;var m=6,w=10,y=15,z=21;s=J(s);C=e(s);Y=1732584193;X=4023233417;W=2562383102;var O_=271733878;for(P=0;P<C.length;P+=16){h=Y;E=X;v=W;g=O_;Y=u(Y,X,W,O_,C[P+0],O,3614090360);O_=u(O_,Y,X,W,C[P+1],V,3905402710);W=u(W,O_,Y,X,C[P+2],N,606105819);X=u(X,W,O_,Y,C[P+3],M,3250441966);Y=u(Y,X,W,O_,C[P+4],O,4118548399);O_=u(O_,Y,X,W,C[P+5],V,1200080426);W=u(W,O_,Y,X,C[P+6],N,2821735955);X=u(X,W,O_,Y,C[P+7],M,4249261313);Y=u(Y,X,W,O_,C[P+8],O,1770035416);O_=u(O_,Y,X,W,C[P+9],V,2336552879);W=u(W,O_,Y,X,C[P+10],N,4294925233);X=u(X,W,O_,Y,C[P+11],M,2304563134);Y=u(Y,X,W,O_,C[P+12],O,1804603682);O_=u(O_,Y,X,W,C[P+13],V,4254626195);W=u(W,O_,Y,X,C[P+14],N,2792965006);X=u(X,W,O_,Y,C[P+15],M,1236535329);Y=f(Y,X,W,O_,C[P+1],A,4129170786);O_=f(O_,Y,X,W,C[P+6],U,3225465664);W=f(W,O_,Y,X,C[P+11],S,643717713);X=f(X,W,O_,Y,C[P+0],R,3921069994);Y=f(Y,X,W,O_,C[P+5],A,3593408605);O_=f(O_,Y,X,W,C[P+10],U,38016083);W=f(W,O_,Y,X,C[P+15],S,3634488961);X=f(X,W,O_,Y,C[P+4],R,3889429448);Y=f(Y,X,W,O_,C[P+9],A,568446438);O_=f(O_,Y,X,W,C[P+14],U,3275163606);W=f(W,O_,Y,X,C[P+3],S,4294588738);X=f(X,W,O_,Y,C[P+8],R,2272392833);Y=f(Y,X,W,O_,C[P+13],A,2850285829);O_=f(O_,Y,X,W,C[P+2],U,4243563512);W=f(W,O_,Y,X,C[P+7],S,1735328473);X=f(X,W,O_,Y,C[P+12],R,2368359562);Y=D(Y,X,W,O_,C[P+5],o,4294588738);O_=D(O_,Y,X,W,C[P+8],T,2272392833);W=D(W,O_,Y,X,C[P+11],Q,1839030562);X=D(X,W,O_,Y,C[P+14],j,4259657740);Y=D(Y,X,W,O_,C[P+1],o,2763975236);O_=D(O_,Y,X,W,C[P+4],T,1272893353);W=D(W,O_,Y,X,C[P+7],Q,4139469664);X=D(X,W,O_,Y,C[P+10],j,3200236656);Y=D(Y,X,W,O_,C[P+13],o,681279174);O_=D(O_,Y,X,W,C[P+0],T,3936430074);W=D(W,O_,Y,X,C[P+3],Q,3572445317);X=D(X,W,O_,Y,C[P+6],j,76029189);Y=D(Y,X,W,O_,C[P+9],o,3654602809);O_=D(O_,Y,X,W,C[P+12],T,3873151461);W=D(W,O_,Y,X,C[P+15],Q,530742520);X=D(X,W,O_,Y,C[P+2],j,3299628645);Y=t(Y,X,W,O_,C[P+0],m,4096336452);O_=t(O_,Y,X,W,C[P+7],w,1126891415);W=t(W,O_,Y,X,C[P+14],y,2878612391);X=t(X,W,O_,Y,C[P+5],z,4237533241);Y=t(Y,X,W,O_,C[P+12],m,1700485571);O_=t(O_,Y,X,W,C[P+3],w,2399980690);W=t(W,O_,Y,X,C[P+10],y,4293915773);X=t(X,W,O_,Y,C[P+1],z,2240044497);Y=t(Y,X,W,O_,C[P+8],m,1873313359);O_=t(O_,Y,X,W,C[P+15],w,4264355552);W=t(W,O_,Y,X,C[P+6],y,2734768916);X=t(X,W,O_,Y,C[P+13],z,1309151649);Y=t(Y,X,W,O_,C[P+4],m,4149444226);O_=t(O_,Y,X,W,C[P+11],w,3174756917);W=t(W,O_,Y,X,C[P+2],y,718787259);X=t(X,W,O_,Y,C[P+9],z,3951481745);Y=K(Y,h);X=K(X,E);W=K(W,v);O_=K(O_,g)}var i=B(Y)+B(X)+B(W)+B(O_);return i.toLowerCase()}

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
