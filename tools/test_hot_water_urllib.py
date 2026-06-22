"""
热水余额端到端诊断脚本（无需安装任何库，纯标准库）

使用方法：复制以下代码到浏览器控制台（F12）运行

注意：这个脚本需要在手机网络（非校园网）下运行，才能真实反映 App 的网络路径
"""
import json, hashlib, time, sys

try:
    import urllib.request as urllib2
    import urllib.parse as urllib_parse
except ImportError:
    import urllib2
    import urllib_parse

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
    data = urllib_parse.urlencode(payload).encode()
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "User-Agent": UA,
    }
    req = urllib2.Request(f"{ECARD}/{path.lstrip('/')}", data=data, headers=headers)
    try:
        resp = urllib2.urlopen(req, timeout=timeout)
        return json.loads(resp.read().decode())
    except urllib2.HTTPError as e:
        return {"_error": f"HTTP {e.code}: {e.reason}", "_body": e.read().decode()[:200]}
    except Exception as e:
        return {"_error": str(e)}


def test_student(student_id):
    print(f"\n{'='*50}")
    print(f"热水余额诊断 — 学号 {student_id}")
    print(f"时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*50)

    # 1. 登录
    print(f"\n[1] 登录 ecarduser.gzus.edu.cn...")
    t0 = time.time()
    d = post_api("user/routine/routine-login", {"from": "wxminiprogram"})
    elapsed = time.time() - t0
    if "_error" in d:
        print(f"  ✗ 登录失败: {d['_error']}")
        if "Name or service not known" in d.get("_error", ""):
            print(f"  原因: DNS 解析失败 — 校园网/外网访问限制")
        return
    print(f"  耗时 {elapsed:.1f}s  code={d.get('code')} ret={d.get('ret')}")
    token = d.get("token", "")
    unionid = d.get("unionid", "")
    if not token:
        print(f"  ✗ 登录失败，无 token: {d}")
        return
    print(f"  ✓ token={token[:20]}...")

    # 2. /waterfee/memberInfo (热水)
    print(f"\n[2] /waterfee/memberInfo (热水余额，只需学号)...")
    t0 = time.time()
    d = post_api(
        "waterfee/memberInfo",
        {"sno": student_id, "implType": "MINGHANBLUETOOTH"},
        token=token, unionid=unionid,
    )
    elapsed = time.time() - t0
    print(f"  耗时 {elapsed:.1f}s")
    if "_error" in d:
        print(f"  ✗ 调用失败: {d['_error']}")
        if elapsed >= 14:
            print(f"  → API 响应慢（{elapsed:.0f}s），可能超时")
        return
    obj = d.get("obj") or {}
    balance = obj.get("balance")
    print(f"  code={d.get('code')} ret={d.get('ret')}")
    print(f"  热水余额: {balance} 元" if balance is not None else f"  热水余额: null（未开通热水账户）")
    print(f"  msg: {d.get('msg', '')}")

    print(f"\n{'='*50}")
    if balance is not None:
        print(f"✓ 热水 API 正常！余额: {balance} 元（响应 {elapsed:.1f}s）")
        print(f"  我的前端修复（EcardDirectClient fallback）可正常工作")
        print(f"  App 更新后，热水余额应能正常显示")
    elif elapsed > 10:
        print(f"✗ API 调用超时（{elapsed:.0f}s）")
        print(f"  从你的网络访问 ecarduser.gzus.edu.cn 较慢")
    else:
        print(f"✗ 热水账户未开通（balance=null）")
        print(f"  请到一卡通中心办理热水账户")


if __name__ == "__main__":
    student_id = sys.argv[1].strip() if len(sys.argv) > 1 else input("学号: ").strip()
    test_student(student_id)
