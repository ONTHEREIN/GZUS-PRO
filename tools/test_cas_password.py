"""
直接测试 CAS 登录密码是否正确（不走 API，绕过登录尝试次数限制）
使用不同的 session，避免复用已锁定的 session。
"""
import base64, re, sys, time
import ddddocr
import requests

CAS_BASE = "https://cas.gzus.edu.cn"
SERVICE_URL = "https://jwxt.seig.edu.cn/sso/lyiotlogin"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0"

RSA_EXPONENT = 0x10001
RSA_MODULUS = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1", 16)


def rsa_encrypt(plaintext: str) -> str:
    modulus_bytes = (RSA_MODULUS.bit_length() + 7) // 8
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
        parts.append(format(pow(m, RSA_EXPONENT, RSA_MODULUS), f"0{hex_digits}x"))
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


def main():
    account = sys.argv[1] if len(sys.argv) > 1 else input("学号: ").strip()
    password = sys.argv[2] if len(sys.argv) > 2 else input("密码: ").strip()

    print("=" * 60)
    print("CAS 密码验证测试（独立 session）")
    print(f"学号: {account}")
    print(f"密码: {password!r}  (长度={len(password)})")
    print("=" * 60)

    ocr = ddddocr.DdddOcr(show_ad=False)

    # 独立 session，不复用任何 cookie
    with requests.Session() as sess:
        sess.headers["User-Agent"] = UA

        # 获取 CAS 页面
        print(f"\n获取 CAS 登录页面...")
        r = sess.get(f"{CAS_BASE}/lyuapServer/login?service={SERVICE_URL}", timeout=15)
        print(f"  状态: {r.status_code}")

        # 获取验证码
        for attempt in range(1, 21):
            ts = str(int(time.time() * 1000))
            r = sess.get(f"{CAS_BASE}/lyuapServer/kaptcha", params={"_t": ts, "uid": ""}, timeout=15)
            data = r.json()
            uid = data.get("uid", "")
            content = data.get("content", "")
            if not content:
                print(f"  尝试 {attempt}: 验证码获取失败")
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

            print(f"    CAS 响应: status={r3.status_code} code_field={code_field} msg={data_obj.get('message', '') if isinstance(data_obj, dict) else ''}")

            if code_field == "USERLOCK":
                lock_msg = data_obj.get("message", "") or data_obj.get("data", "") or "未知"
                print(f"\n  ✗ 账号已锁定: {lock_msg}")
                print(f"    提示: 等待几分钟后再试，或联系管理员解锁")
                return
            elif code_field == "PASSERROR":
                print(f"    → 密码错误 (PASSERROR)")
                # 继续尝试（换验证码）
                continue
            elif code_field is None and resp_data.get("ticket"):
                print(f"  ✓ 登录成功! ticket={resp_data['ticket'][:20]}...")
                tgt = resp_data.get("tgt", "")
                print(f"    tgt={tgt[:20] if tgt else 'N/A'}...")
                # 跟随重定向
                r4 = sess.get(f"{SERVICE_URL}?ticket={resp_data['ticket']}", allow_redirects=True, timeout=15)
                print(f"    重定向: {r4.status_code} → {r4.url}")
                return
            elif resp_data.get("ticket"):
                print(f"  ✓ 登录成功! ticket={resp_data['ticket'][:20]}...")
            else:
                print(f"    其他响应: {resp_data}")
                continue

        print(f"\n  所有验证码尝试失败（可能是账号已锁定）")


if __name__ == "__main__":
    main()
