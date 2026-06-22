/**
 * OneGZUS 热水余额 API 链路测试
 * 用法：打开浏览器 → 登录 https://onegzus.cc.cd → F12 控制台 → 粘贴运行
 */
(async () => {
  const host = 'https://onegzus.cc.cd';
  const account = '2540232101';
  const password = 'Limuliseig423.';

  // RSA-OAEP 加密
  async function rsaEncrypt(plaintext, pemKey) {
    const pemBody = pemKey
      .replace('-----BEGIN PUBLIC KEY-----', '')
      .replace('-----END PUBLIC KEY-----')
      .replace(/\s/g, '');
    const binaryStr = atob(pemBody);
    const bytes = new Uint8Array(binaryStr.length);
    for (let i = 0; i < binaryStr.length; i++) bytes[i] = binaryStr.charCodeAt(i);
    const cryptoKey = await crypto.subtle.importKey(
      'spki', bytes.buffer, { name: 'RSAES-PKCS1-v1_5', hash: 'SHA-256' }, false, ['encrypt']
    );
    const encryptedBytes = await crypto.subtle.encrypt(
      { name: 'RSAES-PKCS1-v1_5' }, cryptoKey, new TextEncoder().encode(plaintext)
    );
    // 转 base64
    let binary = '';
    const buf = new Uint8Array(encryptedBytes);
    for (let i = 0; i < buf.length; i++) binary += String.fromCharCode(buf[i]);
    return btoa(binary);
  }

  async function api(url, options = {}) {
    const r = await fetch(url, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'OneGZUS/1.0',
        ...(options.headers || {})
      },
    });
    try {
      const j = await r.json();
      return { status: r.status, data: j };
    } catch {
      return { status: r.status, data: await r.text() };
    }
  }

  const log = (msg, type = 'info') => console[type === 'err' ? 'error' : 'log'](`[OneGZUS] ${msg}`);

  log('热水余额链路测试开始', 'info');

  // 1. 获取 public key
  log('获取 public key...');
  const { data: pk } = await api(`${host}/auth/public-key`);
  if (!pk.keyId) { log('获取 key 失败: ' + JSON.stringify(pk), 'err'); return; }
  log(`✓ keyId=${pk.keyId}`);

  // 2. 登录
  log('API auto-login...');
  const encryptedPwd = await rsaEncrypt(password, pk.publicKey);
  const { data: loginResp, status: loginStatus } = await api(`${host}/auth/auto-login`, {
    method: 'POST',
    body: JSON.stringify({ account, encryptedPassword: encryptedPwd, keyId: pk.keyId }),
  });
  if (loginStatus !== 200 || !loginResp.sessionId) {
    log(`登录失败 ${loginStatus}: ` + JSON.stringify(loginResp), 'err');
    return;
  }
  const sid = loginResp.sessionId;
  log(`✓ sessionId=${sid.substring(0, 20)}...`);

  // 3. GET /ecard/summary
  log('GET /ecard/summary (当前缓存)...');
  const { data: summary } = await api(`${host}/ecard/summary`, {
    headers: { 'X-Session-Id': sid },
  });
  log(`status=${summary.status} 宿舍=${summary.roomDisplay || '-'}`);
  log(`电费=${summary.powerText || '-'}`);
  log(`冷水=${summary.coldWaterText || '-'}`);
  const hotText = summary.hotWaterText || '-';
  const hotBal = summary.hotWaterBalance;
  log(`热水=${hotText}${hotBal != null ? ' ✓(' + hotBal + ')' : ' ✗(缓存=null)'}`);

  // 4. POST /ecard/refresh
  log('POST /ecard/refresh (完整链路，50s超时)...');
  const { status: refreshStatus, data: refresh } = await api(`${host}/ecard/refresh`, {
    method: 'POST',
    headers: { 'X-Session-Id': sid, 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });

  log(`刷新状态码: ${refreshStatus}`);
  if (refreshStatus === 200) {
    log(`电费=${refresh.powerText || '-''} 冷水=${refresh.coldWaterText || '-'}`);
    const h = refresh.hotWaterBalance;
    log(`热水=${refresh.hotWaterText || '-''} ${h != null ? '✓ 余额=' + h + '元' : '✗ null'}`);
    log(h != null ? '✓✓ 热水余额正常！' : '✗✗ 热水余额为 null（API 超时或学校接口无返回）');
  } else if (refreshStatus === 502) {
    log('✗✗ 502 Bad Gateway — Vercel 调用学校 API 超时', 'err');
    log('  原因: Vercel -> ecarduser.gzus.edu.cn 网络不通/超时', 'err');
    log('  解决: 部署后端热水缓存更新（refresh_binding fallback）', 'err');
  } else {
    log('刷新结果: ' + JSON.stringify(refresh), 'err');
  }
})();
