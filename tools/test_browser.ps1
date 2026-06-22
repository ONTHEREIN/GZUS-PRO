# agent-browser 测试脚本
# 运行: powershell -File test_browser.ps1

$ErrorActionPreference = "Continue"

Write-Host "========== OneGZUS 热水余额浏览器测试 ==========" -ForegroundColor Cyan

# Step 1: 打开 OneGZUS
Write-Host "`n[1/4] 打开 OneGZUS 应用..." -ForegroundColor Yellow
agent-browser open https://onegzus.cc.cd 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Step 2: 截图首页
Write-Host "[2/4] 截图首页..." -ForegroundColor Yellow
agent-browser screenshot "d:/REINs/Documents/GZUS-PRO/screenshots/01_home.png" 2>&1

# Step 3: 查看页面元素
Write-Host "[3/4] 获取页面元素..." -ForegroundColor Yellow
$elements = agent-browser snapshot -i 2>&1 | Out-String
Write-Host $elements
$elements | Out-File "d:/REINs/Documents/GZUS-PRO/screenshots/01_snapshot.txt" -Encoding UTF8

# Step 4: 在控制台执行 JavaScript 测试脚本
Write-Host "`n[4/4] 在页面控制台执行热水余额测试脚本..." -ForegroundColor Yellow

$jsCode = @'
(async () => {
  const host = 'https://onegzus.cc.cd';
  const account = '2540232101';
  const password = 'Limuliseig423.';

  async function rsaEncrypt(plaintext, pemKey) {
    const pemBody = pemKey.replace('-----BEGIN PUBLIC KEY-----','').replace('-----END PUBLIC KEY-----').replace(/\s/g,'');
    const binaryStr = atob(pemBody);
    const bytes = new Uint8Array(binaryStr.length);
    for(let i=0;i<binaryStr.length;i++) bytes[i]=binaryStr.charCodeAt(i);
    const cryptoKey = await crypto.subtle.importKey('spki', bytes.buffer, {name:'RSAES-PKCS1-v1_5',hash:'SHA-256'},false,['encrypt']);
    const encryptedBytes = await crypto.subtle.encrypt({name:'RSAES-PKCS1-v1_5'}, cryptoKey, new TextEncoder().encode(plaintext));
    let binary = ''; const buf = new Uint8Array(encryptedBytes);
    for(let i=0;i<buf.length;i++) binary += String.fromCharCode(buf[i]);
    return btoa(binary);
  }

  async function api(url, options = {}) {
    const r = await fetch(url, {...options, headers:{'Content-Type':'application/json','User-Agent':'OneGZUS/1.0',...(options.headers||{})}});
    try { return {status:r.status, data:await r.json()}; } catch { return {status:r.status, data:await r.text()}; }
  }

  const log = (msg) => console.log('[OneGZUS]', msg);
  log('热水余额链路测试开始');

  // 获取 public key
  log('获取 public key...');
  const pkResp = await api(`${host}/auth/public-key`);
  if(!pkResp.data.keyId) { log('获取 key 失败'); return; }
  log(`✓ keyId=${pkResp.data.keyId}`);

  // 登录
  log('API auto-login...');
  const encryptedPwd = await rsaEncrypt(password, pkResp.data.publicKey);
  const loginResp = await api(`${host}/auth/auto-login`, {
    method:'POST',
    body: JSON.stringify({account, encryptedPassword:encryptedPwd, keyId:pkResp.data.keyId})
  });
  const sid = loginResp.data.sessionId;
  if(!sid) { log('登录失败: ' + JSON.stringify(loginResp.data)); return; }
  log(`✓ sessionId=${sid.substring(0,20)}...`);

  // 获取 summary
  log('GET /ecard/summary...');
  const summary = await api(`${host}/ecard/summary`, {headers:{'X-Session-Id':sid}});
  log(`宿舍=${summary.data.roomDisplay||'-'}`);
  log(`电费=${summary.data.powerText||'-'}`);
  log(`冷水=${summary.data.coldWaterText||'-'}`);
  const h = summary.data.hotWaterBalance;
  log(`热水=${summary.data.hotWaterText||'-'} ${h!=null?'✓余额='+h+'元':'✗null'}`);

  // 刷新余额
  log('POST /ecard/refresh (50s超时)...');
  try {
    const controller = new AbortController();
    const tid = setTimeout(()=>controller.abort(), 50000);
    const refresh = await api(`${host}/ecard/refresh`, {
      method:'POST',
      headers:{'X-Session-Id':sid,'Content-Type':'application/json'},
      body: JSON.stringify({}),
      signal: controller.signal
    });
    clearTimeout(tid);
    const rh = refresh.data.hotWaterBalance;
    const rhText = refresh.data.hotWaterText||'-';
    log(`刷新结果: 电费=${refresh.data.powerText||'-'} 冷水=${refresh.data.coldWaterText||'-'}`);
    log(`热水=${rhText} ${rh!=null?'✓✓余额='+rh+'元':'✗✗null'}`);
    // 返回给外部
    window._testResult = {status: refresh.status, hotBalance: rh, hotText: rhText};
  } catch(e) {
    log('✗ /ecard/refresh 失败: ' + e.message);
    window._testResult = {error: e.message};
  }
})();
'@

# 使用 JavaScript eval 来执行
Write-Host "正在浏览器控制台执行热水测试脚本..." -ForegroundColor Cyan
agent-browser eval $jsCode --stdin 2>&1

# 等待一段时间让测试完成
Write-Host "等待测试完成 (30秒)..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# 获取测试结果
Write-Host "`n获取测试结果..." -ForegroundColor Yellow
$result = agent-browser eval "JSON.stringify(window._testResult || 'no result')" 2>&1
Write-Host "测试结果: $result" -ForegroundColor Green

# 最终截图
Write-Host "`n最终截图..." -ForegroundColor Yellow
agent-browser screenshot "d:/REINs/Documents/GZUS-PRO/screenshots/02_final.png" 2>&1

Write-Host "`n========== 测试完成 ==========" -ForegroundColor Cyan
Write-Host "截图已保存到 screenshots/ 目录" -ForegroundColor Gray
Write-Host "请检查截图和测试结果" -ForegroundColor Gray
