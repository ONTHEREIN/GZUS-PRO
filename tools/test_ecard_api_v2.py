"""
热水余额完整 API 链路测试（使用正确密码）
绕过 CAS，直接测试完整 API 链路
"""
import base64, json, hashlib, re, sys, time
import ddddocr
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding
from cryptography.hazmat.backends import default_backend

API_BASE = "https://onegzus.cc.cd/api"
CAS_BASE = "https://cas.gzus.edu.cn"
UA = "Mozilla/5.0 OneGZUS/1.0"

RSA_MOD = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1", 16)
RSA_EXP = 0x10001

ACCOUNT = "2540232101"
PASSWORD = "Limuliseig423."


def rsa_encrypt(plaintext: str) -> str:
    md = (RSA_MOD.bit_length() + 7) // 8
    nd = md // 2
    hd = nd * 4
    codes = [ord(c) for c in plaintext]
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


def solve_captcha(ocr_text: str) -> str | None:
    fixes = {"o": "0", "O": "0", "l": "1", "I": "1", "S": "5", "s": "5",
             "b": "6", "G": "6", "B": "8", "g": "9", "q": "9"}
    for raw in (ocr_text.strip(),
                "".join(fixes.get(ch, ch) if ch not in "+-*/xX×÷=" else ch
                        for ch in ocr_text.strip())):
        m = re.search(r"(\d+)\s*([+\-*/xX×÷])\s*(\d+)", raw)
        if not m:
            continue
        a, op, b = int(m.group(1)), m.group(2), int(m.group(3))
        if a == 0 or b == 0 or a > 20 or b > 20:
            continue
        ops = {"+": a + b, "-": a - b, "x": a * b, "X": a * b,
               "*": a * b, "×": a * b, "/": a // b, "÷": a // b}
        r = ops.get(op)
        if r is not None and 0 <= r <= 82:
            return str(r)
    return None


def cas_login() -> str:
    """CAS 登录，返回 ticket"""
    print(f"[1] CAS 登录...")
    ocr = ddddocr.DdddOcr(show_ad=False)
    with requests.Session() as s:
        s.headers["User-Agent"] = UA
        s.get(f"{CAS_BASE}/lyuapServer/login?service=https://jwxt.seig.edu.cn/sso/lyiotlogin", timeout=15)
        for attempt in range(1, 21):
            r = s.get(f"{CAS_BASE}/lyuapServer/kaptcha",
                       params={"_t": str(int(time.time() * 1000)), "uid": ""}, timeout=15)
            d = r.json()
            uid = d.get("uid", "")
            content = d.get("content", "")
            if not content:
                continue
            b64 = content.split(",", 1)[1]
            img = base64.b64decode(b64)
            ocr_r = ocr.classification(img)
            code = solve_captcha(ocr_r)
            print(f"  尝试 {attempt}: OCR=[{ocr_r}] -> {code}")
            if not code:
                continue
            ep = rsa_encrypt(PASSWORD)
            ts = str(int(time.time() * 1000))
            tk = rsa_encrypt(f"lyasp{ts}")
            fd = {"username": ACCOUNT, "password": ep, "service": "https://jwxt.seig.edu.cn/sso/lyiotlogin",
                  "loginType": "", "id": uid, "code": code}
            r3 = s.post(f"{CAS_BASE}/lyuapServer/v1/tickets",
                         data=fd, headers={"token": tk, "Content-Type": "application/x-www-form-urlencoded"}, timeout=30)
            rd = r3.json()
            if rd.get("ticket"):
                print(f"  ✓ CAS 登录成功 ticket={rd['ticket'][:20]}...")
                return rd["ticket"]
        raise RuntimeError("CAS 验证码识别失败")


def api_login() -> str:
    """API auto-login，返回 sessionId"""
    print(f"[2] API auto-login...")
    r = requests.get(f"{API_BASE}/auth/public-key", timeout=15)
    pk = r.json()
    pub = serialization.load_pem_public_key(pk["publicKey"].encode(), backend=default_backend())
    enc = pub.encrypt(PASSWORD.encode("utf-8"), asym_padding.PKCS1v15())
    r = requests.post(
        f"{API_BASE}/auth/auto-login",
        json={"account": ACCOUNT, "encryptedPassword": base64.b64encode(enc).decode(), "keyId": pk["keyId"]},
        headers={"Content-Type": "application/json", "User-Agent": UA},
        timeout=120,
    )
    result = r.json()
    sid = result.get("sessionId", "")
    print(f"  ✓ sessionId={sid[:16]}...")
    return sid


def main():
    print("=" * 60)
    print("热水余额完整链路测试")
    print(f"学号: {ACCOUNT}  密码: {PASSWORD!r}")
    print("=" * 60)

    sid = api_login()

    # Step 3: GET /ecard/summary
    print(f"\n[3] GET /ecard/summary...")
    r = requests.get(f"{API_BASE}/ecard/summary",
                     headers={"X-Session-Id": sid, "User-Agent": UA}, timeout=15)
    s = r.json()
    print(f"  status={s.get('status')}")
    print(f"  宿舍={s.get('roomDisplay')}")
    print(f"  电费={s.get('powerText')}")
    print(f"  冷水={s.get('coldWaterText')}")
    hot_b = s.get("hotWaterBalance")
    hot_t = s.get("hotWaterText")
    print(f"  热水={hot_t or '-'}", end="")
    print(f"  ({hot_b})" if hot_b is not None else " (缓存=null)")
    print(f"  updatedAt={s.get('updatedAt')}")

    # Step 4: POST /ecard/refresh
    print(f"\n[4] POST /ecard/refresh (完整链路，60s超时)...")
    t0 = time.time()
    try:
        r = requests.post(
            f"{API_BASE}/ecard/refresh",
            json={},
            headers={"X-Session-Id": sid, "User-Agent": UA, "Content-Type": "application/json"},
            timeout=60,
        )
        elapsed = time.time() - t0
        print(f"  状态: {r.status_code}  耗时 {elapsed:.1f}s")
    except requests.exceptions.Timeout:
        elapsed = time.time() - t0
        print(f"  ✗ 请求超时 {elapsed:.1f}s")
        r = None
    except requests.exceptions.ConnectionError as e:
        elapsed = time.time() - t0
        print(f"  ✗ 连接失败: {e}")
        r = None

    print(f"\n{'=' * 60}")
    print("结果:")
    if r is not None and r.status_code == 200:
        d = r.json()
        print(f"  电费={d.get('powerText') or '-'}")
        print(f"  冷水={d.get('coldWaterText') or '-'}")
        hb = d.get("hotWaterBalance")
        ht = d.get("hotWaterText")
        if hb is not None:
            print(f"\n✓✓ 热水余额正常: {ht or str(hb) + ' 元'}")
        else:
            print(f"\n✗✗ 热水余额为 null!")
            print(f"  /powerfee/getBalance 未返回 hotWaterBalance 且 fallback 失败")
    elif r is not None and r.status_code == 502:
        print(f"\n✗✗ 502 Bad Gateway (Vercel -> 学校 API 超时)")
        print(f"  原因: Vercel 后端调用 ecarduser.gzus.edu.cn 超时")
        print(f"  解决: 部署热水缓存 fallback 后端更新")
    elif r is not None:
        print(f"\n✗ 响应异常: {r.status_code} {r.text[:200]}")
    else:
        print(f"\n✗ 请求失败")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n中断")
    except Exception as exc:
        print(f"\n错误: {exc}")
