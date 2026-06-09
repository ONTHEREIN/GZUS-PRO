from __future__ import annotations

import base64
import logging
import re
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, parse_qsl, urlencode, urlparse, urlunparse

import httpx

from app.captcha_ocr import captcha_ocr

logger = logging.getLogger(__name__)
_SENSITIVE_QUERY_KEYS = {"ticket", "token", "tgt", "password"}

DEFAULT_CAS_URL = (
    "https://cas.gzus.edu.cn/lyuapServer/login"
    "?service=https%3A%2F%2Fjwxt.seig.edu.cn%2Fsso%2Flyiotlogin"
)
DEFAULT_EHALL_URL = "https://ehall.gzus.edu.cn"

# Allow many retries since OCR can be unreliable
MAX_CAPTCHA_RETRIES = 15


def _redact_url(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.query:
        return url
    query = [
        (key, "[REDACTED]" if key.lower() in _SENSITIVE_QUERY_KEYS else value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
    ]
    return urlunparse(parsed._replace(query=urlencode(query)))

# RSA public key components extracted from CAS frontend JS
_RSA_PUBLIC_EXPONENT = 0x010001
_RSA_MODULUS = int(
    "00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5"
    "fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136ea"
    "eb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431"
    "604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117"
    "e7b1",
    16,
)
_RSA_TAG = "lyasp"

# CAS login error codes (from frontend JS analysis)
_CODE_FALSE = "FALSE"  # wrong credentials
_CODE_CAPTCHA_FALSE = "CODEFALSE"  # wrong captcha
_CODE_PASS_ERROR = "PASSERROR"  # password error (with lock info)
_CODE_NO_USER = "NOUSER"  # account not found
_CODE_USER_DISABLED = "USERDISABLED"  # account disabled
_CODE_USER_LOCK = "USERLOCK"  # account locked
_CODE_NEED_2FA = "ISPHONEOREMAILORANSWER"  # need 2FA
_CODE_NEED_CHANGE_PASS = "ISMODIFYPASS"  # need to change password
_CODE_NETWORK_COMMIT = "NETWORKCOMMITMENT"  # network commitment needed
_CODE_MULTI_ACCOUNT = "PEOPLEMOREACCOUNT"  # multiple accounts

# Common OCR misrecognition corrections for arithmetic captchas
# Only applied when the raw OCR text fails to parse as a valid expression
_OCR_CHAR_FIXES = {
    "o": "0", "O": "0",
    "l": "1", "I": "1", "|": "1",
    "S": "5", "s": "5",
    "b": "6", "G": "6",
    "B": "8",
    "g": "9", "q": "9",
}


@dataclass
class CasLoginResult:
    account: str
    cookies: str  # jwxt cookies as header string
    ehall_cookies: str | None = None
    ehall_auth_token: str | None = None
    error: str | None = None
    httpx_client: Any | None = None


def _rsa_encrypt(plaintext: str) -> str:
    """Encrypt plaintext using BigInt.js-style RSA (zero-padded, no PKCS#1).

    This matches the CAS frontend's encryptedString function which uses
    Dave Shapiro's BigInt library with custom zero-padding instead of
    standard PKCS#1 v1.5 padding.

    Algorithm:
    1. Convert each char to its charCode
    2. Pad with zeros to chunkSize boundary
    3. Pack 2 bytes per BigInt digit (little-endian: low + high<<8)
    4. RSA encrypt each chunk: c = m^e mod n
    5. Convert result to zero-padded hex string
    6. Join chunks with spaces
    """
    # Calculate chunk parameters based on key size
    modulus_bytes = (_RSA_MODULUS.bit_length() + 7) // 8  # 128 for 1024-bit
    num_digits = modulus_bytes // 2  # 64 BigInt digits (16-bit each)
    chunk_size = num_digits  # chars per chunk
    hex_digits_per_chunk = num_digits * 4  # 256 hex chars per encrypted chunk

    # Convert plaintext to char codes
    char_codes = [ord(c) for c in plaintext]

    # Pad with zeros to chunkSize boundary
    while len(char_codes) % chunk_size != 0:
        char_codes.append(0)

    # Process in chunks
    result_parts: list[str] = []
    for i in range(0, len(char_codes), chunk_size):
        chunk = char_codes[i : i + chunk_size]

        # Pack 2 bytes per BigInt digit (little-endian)
        # JS: c.digits[r] = n[l++]; c.digits[r] += n[l++] << 8
        m = 0
        for r in range(len(chunk) // 2):
            low = chunk[r * 2]
            high = chunk[r * 2 + 1]
            digit_val = low + (high << 8)
            m += digit_val << (16 * r)

        # RSA encrypt: c = m^e mod n
        c = pow(m, _RSA_PUBLIC_EXPONENT, _RSA_MODULUS)

        # Convert to hex, zero-padded to digitSize * 4 hex chars
        hex_str = format(c, f"0{hex_digits_per_chunk}x")
        result_parts.append(hex_str)

    return " ".join(result_parts)


def _fix_ocr_chars(text: str) -> str:
    """Fix common OCR misrecognition in arithmetic captcha text."""
    result = []
    for ch in text:
        if ch in "+-*/xX×÷=":
            result.append(ch)
        else:
            result.append(_OCR_CHAR_FIXES.get(ch, ch))
    return "".join(result)


def _solve_arithmetic_captcha(ocr_text: str) -> str | None:
    """Parse arithmetic expression from OCR result and compute the answer.

    Tries both raw text and with common OCR character fixes applied.
    Returns None if the expression cannot be reliably parsed.
    """
    for text in (ocr_text.strip(), _fix_ocr_chars(ocr_text.strip())):
        match = re.search(r"(\d+)\s*([+\-*/xX×÷])\s*(\d+)", text)
        if not match:
            continue
        a, op, b = int(match.group(1)), match.group(2), int(match.group(3))
        # Sanity: captcha operands are small (1-9), reject obviously wrong parses
        if a > 20 or b > 20:
            continue
        if a == 0 or b == 0:
            continue  # captchas don't use 0 as operand
        ops = {
            "+": a + b, "-": a - b,
            "x": a * b, "X": a * b, "*": a * b, "×": a * b,
            "/": a // b, "÷": a // b,
        }
        result = ops.get(op)
        if result is not None and 0 <= result <= 82:
            return str(result)
    return None


class CasAutoLogin:
    def __init__(
        self,
        cas_url: str = DEFAULT_CAS_URL,
        ehall_url: str = DEFAULT_EHALL_URL,
        timeout: int = 30,
    ) -> None:
        self.cas_url = cas_url
        self.ehall_url = ehall_url
        self.timeout = timeout

        parsed = urlparse(cas_url)
        self._cas_base = f"{parsed.scheme}://{parsed.netloc}"
        self._service_url = parse_qs(parsed.query).get("service", [None])[0] or ""
        # Build the full CAS login URL with service param
        if self._service_url:
            self._cas_login_url = cas_url
        else:
            # No service in URL — derive from ehall_url or use default
            if ehall_url:
                self._service_url = ehall_url.rstrip("/") + "/shiro-cas"
            self._cas_login_url = f"{self._cas_base}/lyuapServer/login"

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def auto_login(self, account: str, password: str) -> CasLoginResult:
        """Orchestrate the full CAS login flow with CAPTCHA retry.

        On success, returns a CasLoginResult with the httpx_client that
        holds the authenticated JWXT session cookies.  Callers should pass
        this client to SchoolSdkClient(..., httpx_client=result.httpx_client)
        so that proxy_request uses the already-authenticated session directly.
        """
        try:
            client = httpx.Client(follow_redirects=False, timeout=self.timeout)
            # Step 1: GET CAS login page to establish session
            # Retry on transient DNS/connection errors
            self._fetch_cas_page_with_retry(client)

            for attempt in range(1, MAX_CAPTCHA_RETRIES + 1):
                # Step 2: GET kaptcha (returns uid + image)
                kaptcha_uid, captcha_bytes = self._download_kaptcha(client)
                if not captcha_bytes:
                    return CasLoginResult(
                        account=account, cookies="", error="无法获取验证码图片"
                    )

                # Step 3: OCR the captcha and solve arithmetic
                try:
                    ocr_text = captcha_ocr.recognize(captcha_bytes)
                except RuntimeError as exc:
                    logger.error("CAPTCHA OCR unavailable: %s", exc)
                    return CasLoginResult(
                        account=account, cookies="", error=str(exc)
                    )
                captcha_code = _solve_arithmetic_captcha(ocr_text)
                logger.info(
                    "CAPTCHA attempt %d/%d: OCR=%r, solved=%s",
                    attempt, MAX_CAPTCHA_RETRIES, ocr_text, captcha_code,
                )
                if not captcha_code:
                    logger.warning("Failed to solve captcha, getting new one")
                    continue

                # Step 4: POST /v1/tickets with RSA-encrypted password
                result = self._submit_login(
                    client, account, password, kaptcha_uid, captcha_code
                )
                if result is not None:
                    if result.error:
                        result.httpx_client = None
                    else:
                        # Switch to follow_redirects for authenticated requests
                        self._enable_follow_redirects(client)
                        result.httpx_client = client
                    return result

                # Login returned CODEFALSE – captcha was wrong, retry
                logger.info("Captcha was wrong on attempt %d, retrying", attempt)

            return CasLoginResult(
                account=account, cookies="", error="验证码识别失败，请重试"
            )
        except Exception as exc:
            logger.exception("CAS auto-login error")
            return CasLoginResult(account=account, cookies="", error=str(exc))

    # ------------------------------------------------------------------
    # Step 1: GET CAS login page (establishes session cookies)
    # ------------------------------------------------------------------

    _CONNECT_RETRIES = 3
    _CONNECT_RETRY_DELAY = 2  # seconds

    @staticmethod
    def _enable_follow_redirects(client: httpx.Client) -> None:
        """Switch the httpx client to follow_redirects=True after CAS login.

        The CAS flow uses follow_redirects=False because we need to
        explicitly handle ticket/TGT redirects.  Once logged in, we need
        follow_redirects=True for normal JWXT API proxy requests.
        """
        client.follow_redirects = True

    def _fetch_cas_page_with_retry(self, client: httpx.Client) -> None:
        """GET the CAS login page with retry on transient DNS/connection errors."""
        last_exc: Exception | None = None
        for i in range(self._CONNECT_RETRIES):
            try:
                logger.debug("Fetching CAS page (attempt %d): %s", i + 1, self._cas_login_url)
                response = client.get(self._cas_login_url, follow_redirects=True)
                response.raise_for_status()
                return
            except httpx.ConnectError as exc:
                last_exc = exc
                logger.warning(
                    "CAS page fetch failed (attempt %d/%d): %s",
                    i + 1, self._CONNECT_RETRIES, exc,
                )
                if i < self._CONNECT_RETRIES - 1:
                    time.sleep(self._CONNECT_RETRY_DELAY)
        raise last_exc  # type: ignore[misc]

    # ------------------------------------------------------------------
    # Step 2: Download kaptcha image + get uid
    # ------------------------------------------------------------------

    def _download_kaptcha(self, client: httpx.Client) -> tuple[str, bytes]:
        """Download kaptcha and return (uid, image_bytes)."""
        timestamp = str(int(time.time() * 1000))
        kaptcha_url = f"{self._cas_base}/lyuapServer/kaptcha"
        logger.debug("Downloading kaptcha: %s", kaptcha_url)
        response = client.get(kaptcha_url, params={"_t": timestamp, "uid": ""})
        response.raise_for_status()

        try:
            data = response.json()
            uid = data.get("uid", "")
            content = data.get("content", "")
            if content and "," in content:
                b64 = content.split(",", 1)[1]
                return uid, base64.b64decode(b64)
            elif content:
                return uid, base64.b64decode(content)
        except Exception as exc:
            logger.warning("Failed to parse kaptcha JSON: %s", exc)

        content_type = response.headers.get("content-type", "")
        if "image" in content_type and response.content:
            return "", response.content

        return "", b""

    # ------------------------------------------------------------------
    # Step 3: Submit login via POST /v1/tickets
    # ------------------------------------------------------------------

    def _submit_login(
        self,
        client: httpx.Client,
        account: str,
        password: str,
        kaptcha_uid: str,
        captcha_code: str,
    ) -> CasLoginResult | None:
        """POST to /v1/tickets with RSA-encrypted password.

        Returns CasLoginResult on success or terminal error,
        or None if captcha error (should retry).
        """
        encrypted_password = _rsa_encrypt(password)
        logger.debug("Encrypted password length: %d", len(encrypted_password))

        timestamp = str(int(time.time() * 1000))
        token = _rsa_encrypt(f"{_RSA_TAG}{timestamp}")
        logger.debug("Encrypted token length: %d", len(token))

        tickets_url = f"{self._cas_base}/lyuapServer/v1/tickets"
        form_data = {
            "username": account,
            "password": encrypted_password,
            "service": self._service_url,
            "loginType": "",
            "id": kaptcha_uid,
            "code": captcha_code,
        }
        headers = {
            "token": token,
            "Content-Type": "application/x-www-form-urlencoded",
        }

        logger.info("POST %s (uid=%s, code=%s)", tickets_url, kaptcha_uid, captcha_code)
        response = client.post(tickets_url, data=form_data, headers=headers)
        logger.info("Login response: status=%d, body=%s", response.status_code, response.text[:300])

        if response.status_code in (200, 201):
            try:
                resp_data = response.json()
                data_obj = resp_data.get("data", {})
                if isinstance(data_obj, dict) and data_obj.get("code"):
                    return self._handle_error_code(account, data_obj, kaptcha_uid)

                ticket = resp_data.get("ticket", "")
                tgt = resp_data.get("tgt", "")

                if ticket:
                    return self._finalize_login(client, account, ticket, tgt)
            except Exception as exc:
                logger.warning("Failed to parse login response: %s", exc)
                if response.status_code == 201:
                    location = response.headers.get("location", "")
                    if location:
                        logger.info("TGT location received")
                        tgt = location.rsplit("/", 1)[-1] if "/" in location else ""
                        st_response = client.post(
                            location,
                            data={"service": self._service_url},
                            headers={"Content-Type": "application/x-www-form-urlencoded"},
                        )
                        if st_response.status_code == 200:
                            ticket = st_response.text.strip()
                            return self._finalize_login(client, account, ticket, tgt)

        logger.warning(
            "Login request returned status %d: %s",
            response.status_code,
            response.text[:500],
        )
        return CasLoginResult(
            account=account,
            cookies="",
            error=f"登录请求失败 (HTTP {response.status_code})",
        )

    def _handle_error_code(
        self, account: str, data_obj: dict, kaptcha_uid: str
    ) -> CasLoginResult | None:
        """Handle CAS error codes. Returns None for retryable errors."""
        code = data_obj.get("code", "")
        uid = data_obj.get("uid", kaptcha_uid)

        if code == _CODE_FALSE:
            return CasLoginResult(account=account, cookies="", error="用户名或密码错误")
        if code == _CODE_CAPTCHA_FALSE:
            logger.info("Captcha code incorrect, will retry (uid=%s)", uid)
            return None  # retry
        if code == _CODE_PASS_ERROR:
            extra = data_obj.get("data", "")
            return CasLoginResult(account=account, cookies="", error=f"密码错误: {extra}")
        if code == _CODE_NO_USER:
            return CasLoginResult(account=account, cookies="", error="账号不存在")
        if code == _CODE_USER_DISABLED:
            return CasLoginResult(account=account, cookies="", error="账号被停用")
        if code == _CODE_USER_LOCK:
            lock_info = data_obj.get("data", "")
            return CasLoginResult(account=account, cookies="", error=f"账号锁定: {lock_info}")
        if code == _CODE_NEED_2FA:
            return CasLoginResult(account=account, cookies="", error="需要二次验证，暂不支持")
        if code == _CODE_NEED_CHANGE_PASS:
            return CasLoginResult(account=account, cookies="", error="需要修改密码，暂不支持")
        if code == _CODE_MULTI_ACCOUNT:
            return CasLoginResult(account=account, cookies="", error="多账号，暂不支持")

        logger.warning("Unknown CAS error code: %s (data=%s)", code, data_obj)
        return CasLoginResult(account=account, cookies="", error=f"登录失败 (code={code})")

    # ------------------------------------------------------------------
    # Step 4: Finalize login – follow service URL with ticket
    # ------------------------------------------------------------------

    def _finalize_login(
        self,
        client: httpx.Client,
        account: str,
        ticket: str,
        tgt: str,
    ) -> CasLoginResult:
        """Follow the service URL with the ticket to establish session cookies."""
        service_url = self._service_url
        if "?" in service_url:
            redirect_url = f"{service_url}&ticket={ticket}"
        else:
            redirect_url = f"{service_url}?ticket={ticket}"

        jwxt_host = urlparse(self._service_url).hostname or "jwxt.seig.edu.cn"
        self._follow_service_ticket(client, redirect_url)
        jwxt_cookies = self._extract_cookies_for_hosts(client, [jwxt_host])
        if not jwxt_cookies and tgt:
            fallback_ticket = self._request_service_ticket(client, tgt, self._service_url)
            if fallback_ticket:
                fallback_url = self._service_ticket_url(self._service_url, fallback_ticket)
                self._follow_service_ticket(client, fallback_url)
                jwxt_cookies = self._extract_cookies_for_hosts(client, [jwxt_host])

        ehall_cookies, ehall_token = self._get_ehall_session(client, tgt)

        if not jwxt_cookies and not ehall_cookies:
            logger.warning("No session cookies obtained after login")

        return CasLoginResult(
            account=account,
            cookies=jwxt_cookies,
            ehall_cookies=ehall_cookies,
            ehall_auth_token=ehall_token,
        )

    def _follow_service_ticket(self, client: httpx.Client, url: str) -> None:
        logger.debug("Following service URL: %s", _redact_url(url))
        try:
            response = client.get(url, follow_redirects=True)
            response.raise_for_status()
        except Exception as exc:
            logger.warning("Failed to follow service URL: %s", exc)

    def _request_service_ticket(
        self,
        client: httpx.Client,
        tgt: str,
        service_url: str,
    ) -> str:
        try:
            tgt_url = f"{self._cas_base}/lyuapServer/v1/tickets/{tgt}"
            response = client.post(
                tgt_url,
                data={"service": service_url},
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            if response.status_code == 200:
                return response.text.strip()
        except Exception as exc:
            logger.warning("Failed to request service ticket: %s", exc)
        return ""

    @staticmethod
    def _service_ticket_url(service_url: str, ticket: str) -> str:
        if "?" in service_url:
            return f"{service_url}&ticket={ticket}"
        return f"{service_url}?ticket={ticket}"

    # ------------------------------------------------------------------
    # Cookie extraction helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _extract_domain_cookies(client: httpx.Client, domain_keyword: str) -> str:
        """Extract cookies matching a domain keyword."""
        cookie_parts: list[str] = []
        for cookie in client.cookies.jar:
            if domain_keyword in (cookie.domain or ""):
                cookie_parts.append(f"{cookie.name}={cookie.value}")
        return "; ".join(cookie_parts) if cookie_parts else ""

    @staticmethod
    def _extract_cookies_for_hosts(client: httpx.Client, hosts: list[str]) -> str:
        """Extract cookies that would be sent to any target host."""
        target_hosts = [host.lower().lstrip(".") for host in hosts if host]
        cookie_parts: list[str] = []
        seen: set[str] = set()
        for cookie in client.cookies.jar:
            domain = (cookie.domain or "").lower().lstrip(".")
            if not domain:
                continue
            if not any(host == domain or host.endswith(f".{domain}") for host in target_hosts):
                continue
            key = cookie.name
            if key in seen:
                continue
            seen.add(key)
            cookie_parts.append(f"{cookie.name}={cookie.value}")
        return "; ".join(cookie_parts) if cookie_parts else ""

    # ------------------------------------------------------------------
    # Ehall session
    # ------------------------------------------------------------------

    def _get_ehall_session(
        self, client: httpx.Client, tgt: str = ""
    ) -> tuple[str | None, str | None]:
        """Get ehall session by using TGT to obtain an ehall service ticket.

        The CAS TGT can be used to request service tickets for any CAS-enabled
        service. We request a ticket for ehall's shiro-cas endpoint, then
        follow the redirect to establish ehall session cookies.
        """
        ehall_service_url = self.ehall_url.rstrip("/") + "/shiro-cas"
        ehall_sid = None

        # Method 1: Use TGT to get ehall service ticket (preferred)
        if tgt:
            try:
                tgt_url = f"{self._cas_base}/lyuapServer/v1/tickets/{tgt}"
                st_response = client.post(
                    tgt_url,
                    data={"service": ehall_service_url},
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                )
                if st_response.status_code == 200:
                    ehall_ticket = st_response.text.strip()
                    if ehall_ticket:
                        redirect_url = f"{ehall_service_url}?ticket={ehall_ticket}"
                        logger.info("Following ehall service URL: %s", _redact_url(redirect_url))
                        client.get(redirect_url, follow_redirects=True)
                        ehall_sid = self._extract_ehall_sid(client)
                        if ehall_sid:
                            logger.info("Got ehall sid via TGT")
            except Exception as exc:
                logger.warning("Failed to get ehall session via TGT: %s", exc)

        # Method 2: Direct navigation fallback
        if not ehall_sid:
            try:
                client.get(f"{self.ehall_url.rstrip('/')}/", follow_redirects=True)
                ehall_sid = self._extract_ehall_sid(client)
            except Exception as exc:
                logger.debug("ehall direct navigation failed: %s", exc)

        if not ehall_sid:
            logger.warning("Failed to obtain ehall session")
            return None, None

        ehall_cookies = f"sid={ehall_sid}"
        return ehall_cookies, None

    @staticmethod
    def _extract_ehall_sid(client: httpx.Client) -> str | None:
        """Extract the ehall 'sid' cookie value."""
        for cookie in client.cookies.jar:
            if "ehall" in (cookie.domain or "") and cookie.name == "sid":
                return cookie.value
        return None
