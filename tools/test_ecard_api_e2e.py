"""
完整 API 链路端到端测试（使用正确的密码）

流程：
  1) CAS 登录（ddddocr 解验证码）获取 CAS session
  2) 创建 API session（使用 RSA 加密密码）
  3) GET /ecard/summary → 获取当前绑定宿舍
  4) POST /ecard/refresh → 刷新余额（走完整链路）
  5) 检查 hotWaterBalance 是否显示

依赖: pip install requests ddddocr cryptography
"""
import base64, json, os, re, sys, time
import ddddocr
import requests
from cryptography.hazmat.primitives import serialization, padding
from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.backends import default_backend

# ─── 配置 ───
API_BASE = "https://onegzus.cc.cd/api"
CAS_BASE = "https://cas.gzus.edu.cn"
SERVICE_URL = "https://jwxt.seig.edu.cn/sso/lyiotlogin"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 OneGZUS/1.0"

RSA_MOD = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1", 16)
RSA_EXP = 0x10001


def rsa_encrypt(plaintext: str) -> str:
    modulus_bytes = (RSA_MOD.bit_length() + 7) // 8
    num_digits = modulus_bytes // 2
    hex_digits = num_digits * 4
    codes = [ord(c) for c in plaintext]
    while len(codes) % num_digits:
        codes.append(0)
    parts = []
    for i in range(0, len(codes), num_digits):
        chunk = codes[i: i + num_digits]
        m = 0
        for r in range(num_digits // 2):
            low, high = chunk[r * 2], chunk[r * 2 + 1]
            m += (low + (high << 8)) << (16 * r)
        parts.append(format(pow(m, RSA_EXP, RSA_MOD), f"0{hex_digits}x"))
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
        result = ops.get(op)
        if result is not None and 0 <= result <= 82:
            return str(result)
    return None


def cas_login(account: str, password: str) -> tuple[str, str]:
    """CAS 登录，返回 (ticket, tgt)"""
    print(f"\n[1] CAS 登录 (account={account})...")
    ocr = ddddocr.DdddOcr(show_ad=False)

    with requests.Session() as sess:
        sess.headers["User-Agent"] = UA

        r = sess.get(f"{CAS_BASE}/lyuapServer/login?service={SERVICE_URL}", timeout=15)
        print(f"  CAS 页面: {r.status_code}")

        for attempt in range(1, 21):
            ts = str(int(time.time() * 1000))
            r = sess.get(f"{CAS_BASE}/lyuapServer/kaptcha", params={"_t": ts, "uid": ""}, timeout=15)
            data = r.json()
            uid = data.get("uid", "")
            content = data.get("content", "")
            if not content:
                continue
            b64 = content.split(",", 1)[1]
            img_bytes = base64.b64decode(b64)

            ocr_result = ocr.classification(img_bytes)
            code = solve_captcha(ocr_result)
            print(f"  尝试 {attempt}: OCR=[{ocr_result}], 解算={code}")
            if not code:
                continue

            encrypted_pwd = rsa_encrypt(password)
            timestamp = str(int(time.time() * 1000))
            token_str = rsa_encrypt(f"lyasp{timestamp}")

            form_data = {
                "username": account,
                "password": encrypted_pwd,
                "service": SERVICE_URL,
                "loginType": "",
                "id": uid,
                "code": code,
            }
            headers = {"token": token_str, "Content-Type": "application/x-www-form-urlencoded"}

            r3 = sess.post(f"{CAS_BASE}/lyuapServer/v1/tickets",
                           data=form_data, headers=headers, timeout=30)
            resp_data = r3.json()
            data_obj = resp_data.get("data", {})
            code_field = data_obj.get("code") if isinstance(data_obj, dict) else None

            if code_field == "USERLOCK":
                lock_msg = data_obj.get("message", "") or data_obj.get("data", "") or "未知"
                print(f"  ✗ 账号锁定: {lock_msg}")
                raise RuntimeError(f"账号锁定: {lock_msg}")
            elif code_field is None and resp_data.get("ticket"):
                ticket = resp_data["ticket"]
                tgt = resp_data.get("tgt", "")
                print(f"  ✓ CAS 登录成功: ticket={ticket[:16]}... tgt={tgt[:16] if tgt else 'N/A'}...")
                # 保存 cookies
                cas_cookies = dict(sess.cookies)
                return ticket, tgt
            else:
                print(f"    code={code_field} msg={data_obj.get('message', '') if isinstance(data_obj, dict) else ''}")
                continue

        raise RuntimeError("CAS 验证码识别失败（21 次尝试）")


def api_auto_login(account: str, password: str) -> str:
    """调用 API auto-login，返回 sessionId"""
    print(f"\n[2] API auto-login (RSA 加密密码)...")
    r = requests.get(f"{API_BASE}/auth/public-key", timeout=15)
    pk_data = r.json()
    key_id = pk_data["keyId"]
    print(f"  publicKey keyId={key_id}")

    pub = serialization.load_pem_public_key(pk_data["publicKey"].encode(), backend=default_backend())
    encrypted = pub.encrypt(password.encode("utf-8"), rsa_padding.PKCS1v15())
    encrypted_b64 = base64.b64encode(encrypted).decode()

    r = requests.post(
        f"{API_BASE}/auth/auto-login",
        json={"account": account, "encryptedPassword": encrypted_b64, "keyId": key_id},
        headers={"Content-Type": "application/json", "User-Agent": UA},
        timeout=120,
    )
    if r.status_code != 200:
        print(f"  ✗ auto-login 失败: {r.status_code} {r.text[:500]}")
        raise RuntimeError(f"API 登录失败: {r.status_code} {r.text[:200]}")
    result = r.json()
    session_id = result.get("sessionId", "")
    print(f"  ✓ API sessionId={session_id[:16] if session_id else 'N/A'}...")
    return session_id


def get_summary(session_id: str) -> dict:
    print(f"\n[3] GET /ecard/summary...")
    r = requests.get(
        f"{API_BASE}/ecard/summary",
        headers={"X-Session-Id": session_id, "User-Agent": UA},
        timeout=15,
    )
    print(f"  状态: {r.status_code}")
    if r.status_code != 200:
        print(f"  {r.text[:300]}")
        return {}
    data = r.json()
    print(f"  status={data.get('status')}  roomDisplay={data.get('roomDisplay') or '未绑定'}")
    print(f"  studentId={data.get('studentId')}")
    return data


def refresh_balance(session_id: str) -> dict:
    print(f"\n[4] POST /ecard/refresh (走完整链路)...")
    t0 = time.time()
    r = requests.post(
        f"{API_BASE}/ecard/refresh",
        json={},
        headers={"X-Session-Id": session_id, "User-Agent": UA, "Content-Type": "application/json"},
        timeout=90,
    )
    elapsed = time.time() - t0
    print(f"  状态: {r.status_code}  耗时 {elapsed:.1f}s")
    if r.status_code != 200:
        print(f"  {r.text[:500]}")
        return {}
    return r.json()


def main():
    account = sys.argv[1] if len(sys.argv) > 1 else input("学号: ").strip()
    password = sys.argv[2] if len(sys.argv) > 2 else input("密码: ").strip()

    print("=" * 60)
    print("热水余额完整 API 链路测试")
    print(f"API: {API_BASE}")
    print(f"学号: {account}")
    print(f"密码: {password!r}")
    print("=" * 60)

    # Step 1: CAS 登录
    try:
        ticket, tgt = cas_login(account, password)
    except RuntimeError:
        raise SystemExit(1)

    # Step 2: API auto-login
    try:
        session_id = api_auto_login(account, password)
    except RuntimeError:
        raise SystemExit(1)

    # Step 3: 获取当前绑定
    summary = get_summary(session_id)
    if summary.get("status") == "not_bound":
        print("\n当前未绑定宿舍，跳过余额查询。")
        print("请先在 App 中绑定宿舍后再测试。")
        raise SystemExit(0)

    # Step 4: 刷新余额
    result = refresh_balance(session_id)

    print(f"\n{'=' * 60}")
    print("余额结果:")
    print(f"  电费: {result.get('powerText') or '-'}")
    print(f"  冷水: {result.get('coldWaterText') or '-'}")
    print(f"  热水: {result.get('hotWaterText') or '-'}")
    print(f"  热水余额 raw: {result.get('hotWaterBalance')}")
    print(f"  更新时间: {result.get('updatedAt') or '-'}")
    print(f"  studentId: {result.get('studentId')}")

    hot_balance = result.get("hotWaterBalance")
    hot_text = result.get("hotWaterText")
    if hot_balance is not None or hot_text:
        print(f"\n✓ 热水余额显示正常: {hot_text or str(hot_balance) + ' 元'}")
    else:
        print(f"\n✗ 热水余额无法显示！")
        print(f"  可能原因:")
        print(f"  1) /powerfee/getBalance 未返回 hotWaterBalance 且 fallback 调用失败")
        print(f"  2) 后端 refresh_binding 未正确调用 /waterfee/memberInfo")
        print(f"  3) session.studentId 为空导致 fallback 未触发")

    print(f"\n完整返回数据:")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except requests.RequestException as exc:
        print(f"\n请求失败: {exc}")
        raise SystemExit(1)
    except RuntimeError as exc:
        print(f"\n错误: {exc}")
        raise SystemExit(1)
