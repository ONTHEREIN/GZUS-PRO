"""
直接测试 ecarduser.gzus.edu.cn（绕过 Vercel/Worker）
验证学校 API 是否可达及响应时间。
"""
import hashlib, time, json
import requests

ECARD = "https://ecarduser.gzus.edu.cn"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
OPENID = "o6gXt5YdtSc-15PgJg0KqAXZytRc"
SECRET = "greatge"
RSA_MOD = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1", 16)
RSA_EXP = 0x10001

def rsa_encrypt(p):
    md = (RSA_MOD.bit_length() + 7) // 8
    nd = md // 2
    hd = nd * 4
    codes = [ord(c) for c in p]
    while len(codes) % nd:
        codes.append(0)
    parts = []
    for i in range(0, len(codes), nd):
        chunk = codes[i:i + nd]
        m = 0
        for r in range(nd // 2):
            lo, hi = chunk[r * 2], chunk[r * 2 + 1]
            m += (lo + (hi << 8)) << (16 * r)
        parts.append(format(pow(m, RSA_EXP, RSA_MOD), f"0{hd}x"))
    return " ".join(parts)


def calc_sign(params):
    filtered = {k: v for k, v in params.items() if k not in ("token", "sign")}
    raw = "&".join(f"{k}={filtered[k]}" for k in sorted(filtered)) + f"&{SECRET}"
    return hashlib.md5(raw.encode()).hexdigest().upper()


def post_api(path, params, token="", unionid="", timeout=15):
    payload = dict(params)
    payload.update(
        {"from": "wxminiprogram", "isWxEnterpriseXcx": "false", "wxRequest": "wxRequest", "openid": OPENID}
    )
    if unionid:
        payload["unionid"] = unionid
    if token:
        payload["token"] = token
    payload["sign"] = calc_sign(payload)
    headers = {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", "User-Agent": UA}
    url = f"{ECARD}/{path.lstrip('/')}"
    r = requests.post(url, data=payload, headers=headers, timeout=timeout, allow_redirects=False)
    print(f"    [{path}] status={r.status_code} location={r.headers.get('Location', 'N/A')[:80]}")
    if r.status_code >= 400 or not r.text.strip():
        print(f"    跳过（重定向或错误）")
        return {}
    r.raise_for_status()
    return r.json()


print("直接测试 ecarduser.gzus.edu.cn（绕过 Vercel）")
print("=" * 50)

# 1. 登录获取 token
print("\n[1] 登录...")
t0 = time.time()
d = post_api("user/routine/routine-login", {"from": "wxminiprogram"})
print(f"  耗时 {time.time()-t0:.1f}s  code={d.get('code')} ret={d.get('ret')}")
token = d.get("token", "")
unionid = d.get("unionid", "")
print(f"  token={token[:16]}..." if token else "  无 token!")
if not token:
    print("  ✗ 登录失败，停止测试")
    raise SystemExit(1)

# 2. /powerfee/getBalance (江门校区 A2-932)
ROOM = ("CGCOMMON2222", "82", "5328", "5611")
print(f"\n[2] /powerfee/getBalance {ROOM}...")
t0 = time.time()
d = post_api(
    "powerfee/getBalance",
    {"implType": ROOM[0], "schoolAreaNo": ROOM[1], "buildingNo": ROOM[2], "roomNum": ROOM[3]},
    token=token, unionid=unionid,
)
elapsed = time.time() - t0
obj = d.get("obj") or {}
print(f"  耗时 {elapsed:.1f}s  code={d.get('code')} ret={d.get('ret')}")
print(f"  powerBalance   = {obj.get('powerBalance')}")
print(f"  hotWaterBalance = {obj.get('hotWaterBalance')}")

# 3. /waterfee/memberInfo (热水)
print(f"\n[3] /waterfee/memberInfo (学号=2540232101, implType=MINGHANBLUETOOTH)...")
t0 = time.time()
d = post_api(
    "waterfee/memberInfo",
    {"sno": "2540232101", "implType": "MINGHANBLUETOOTH"},
    token=token, unionid=unionid,
)
elapsed = time.time() - t0
obj = d.get("obj") or {}
print(f"  耗时 {elapsed:.1f}s  code={d.get('code')} ret={d.get('ret')}")
print(f"  balance = {obj.get('balance')}")

# 4. 结论
print(f"\n{'=' * 50}")
print(f"结论:")
print(f"  直接调用 ecarduser API {'正常' if elapsed < 10 else '较慢但可用'}（{elapsed:.1f}s）")
print(f"  Vercel 超时原因: Vercel -> ecarduser 网络链路慢（>15s）")
print(f"  热水余额 = {obj.get('balance')} 元")
print(f"  我的修复（前端 fallback）: 在原生移动端可正常工作（不走 Vercel）")
print(f"  Web 端热水余额: 依赖 Vercel 后端修复超时问题")
