"""Test full login flow with real account - check cookie extraction."""
from __future__ import annotations

import base64
import getpass
import re
import time
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import ddddocr
import httpx

CAS_BASE = "https://cas.gzus.edu.cn"
SERVICE_URL = "https://jwxt.seig.edu.cn/sso/lyiotlogin"
_SENSITIVE_QUERY_KEYS = {"ticket", "token", "tgt", "password"}

RSA_EXPONENT = 0x010001
RSA_MODULUS = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1",
    16,
)


def bigint_encrypt(plaintext: str) -> str:
    modulus_bytes = (RSA_MODULUS.bit_length() + 7) // 8
    num_digits = modulus_bytes // 2
    chunk_size = num_digits
    hex_digits_per_chunk = num_digits * 4
    char_codes = [ord(c) for c in plaintext]
    while len(char_codes) % chunk_size != 0:
        char_codes.append(0)
    result_parts = []
    for i in range(0, len(char_codes), chunk_size):
        chunk = char_codes[i : i + chunk_size]
        m = 0
        for r in range(len(chunk) // 2):
            low = chunk[r * 2]
            high = chunk[r * 2 + 1]
            m += (low + (high << 8)) << (16 * r)
        c = pow(m, RSA_EXPONENT, RSA_MODULUS)
        result_parts.append(format(c, f"0{hex_digits_per_chunk}x"))
    return " ".join(result_parts)


def solve_captcha(ocr_text: str) -> str | None:
    fixes = {"o": "0", "O": "0", "l": "1", "I": "1", "S": "5", "s": "5", "b": "6", "G": "6", "B": "8", "g": "9", "q": "9"}
    for raw in (ocr_text.strip(), "".join(fixes.get(ch, ch) if ch not in "+-*/xX×÷=" else ch for ch in ocr_text.strip())):
        match = re.search(r"(\d+)\s*([+\-*/xX×÷])\s*(\d+)", raw)
        if not match:
            continue
        a, op, b = int(match.group(1)), match.group(2), int(match.group(3))
        if a == 0 or b == 0 or a > 20 or b > 20:
            continue
        ops = {"+": a + b, "-": a - b, "x": a * b, "X": a * b, "*": a * b, "×": a * b, "/": a // b, "÷": a // b}
        result = ops.get(op)
        if result is not None and 0 <= result <= 82:
            return str(result)
    return None


def _redact(value: str, keep: int = 6) -> str:
    if not value:
        return ""
    if len(value) <= keep:
        return "[REDACTED]"
    return f"{value[:keep]}...[REDACTED]"


def _redact_url(url: object) -> str:
    parsed = urlparse(str(url))
    query = [
        (key, "[REDACTED]" if key.lower() in _SENSITIVE_QUERY_KEYS else value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
    ]
    return urlunparse(parsed._replace(query=urlencode(query)))


def main():
    import sys
    account = sys.argv[1] if len(sys.argv) > 1 else input("Account: ")
    password = sys.argv[2] if len(sys.argv) > 2 else getpass.getpass("Password: ")

    ocr = ddddocr.DdddOcr(show_ad=False)

    with httpx.Client(follow_redirects=False, timeout=30) as client:
        # Step 1: Fetch CAS page
        cas_url = f"{CAS_BASE}/lyuapServer/login?service={SERVICE_URL}"
        client.get(cas_url, follow_redirects=True)

        for attempt in range(1, 16):
            ts = str(int(time.time() * 1000))
            r = client.get(f"{CAS_BASE}/lyuapServer/kaptcha", params={"_t": ts, "uid": ""})
            data = r.json()
            uid = data.get("uid", "")
            content = data.get("content", "")
            b64 = content.split(",", 1)[1]
            img_bytes = base64.b64decode(b64)

            ocr_result = ocr.classification(img_bytes)
            captcha_code = solve_captcha(ocr_result)
            print(f"Attempt {attempt}: OCR=[{ocr_result}], solved={captcha_code}")

            if not captcha_code:
                continue

            # Login
            encrypted_password = bigint_encrypt(password)
            timestamp = str(int(time.time() * 1000))
            token = bigint_encrypt(f"lyasp{timestamp}")

            form_data = {
                "username": account,
                "password": encrypted_password,
                "service": SERVICE_URL,
                "loginType": "",
                "id": uid,
                "code": captcha_code,
            }
            headers = {
                "token": token,
                "Content-Type": "application/x-www-form-urlencoded",
            }

            r3 = client.post(f"{CAS_BASE}/lyuapServer/v1/tickets", data=form_data, headers=headers)
            print(f"\nLogin response: status={r3.status_code}")
            print("Body: <redacted>")

            if r3.status_code not in (200, 201):
                continue

            resp_data = r3.json()
            data_obj = resp_data.get("data", {})
            if isinstance(data_obj, dict) and data_obj.get("code"):
                print(f"Error code: {data_obj.get('code')}")
                continue

            ticket = resp_data.get("ticket", "")
            tgt = resp_data.get("tgt", "")
            print(f"\nLogin SUCCESS! ticket={_redact(ticket)}, tgt={_redact(tgt)}")

            # Step: Follow service URL with ticket
            redirect_url = f"{SERVICE_URL}?ticket={ticket}"
            print(f"\nFollowing: {_redact_url(redirect_url)}")

            r4 = client.get(redirect_url, follow_redirects=True)
            print(f"Status: {r4.status_code}")
            print(f"Final URL: {_redact_url(r4.url)}")
            print(f"Response length: {len(r4.text)}")

            # Check all cookies
            print(f"\nAll cookies after redirect:")
            for cookie in client.cookies.jar:
                print(f"  {cookie.domain} | {cookie.name} = {_redact(cookie.value)}")

            # Check jwxt cookies specifically
            jwxt_cookies = []
            for cookie in client.cookies.jar:
                if "jwxt" in (cookie.domain or ""):
                    jwxt_cookies.append(f"{cookie.name}={_redact(cookie.value)}")
            print(f"\njwxt cookies: {'; '.join(jwxt_cookies) if jwxt_cookies else 'NONE'}")

            # Also try ehall
            try:
                r5 = client.get("https://ehall.gzus.edu.cn/", follow_redirects=True)
                print(f"\nehall status: {r5.status_code}")
                ehall_cookies = []
                for cookie in client.cookies.jar:
                    if "ehall" in (cookie.domain or ""):
                        ehall_cookies.append(f"{cookie.name}={_redact(cookie.value)}")
                print(f"ehall cookies: {'; '.join(ehall_cookies) if ehall_cookies else 'NONE'}")
            except Exception as e:
                print(f"ehall error: {e}")

            break


if __name__ == "__main__":
    main()
