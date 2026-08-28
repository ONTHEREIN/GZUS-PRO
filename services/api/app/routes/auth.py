from dataclasses import dataclass
from hashlib import sha256
from hmac import compare_digest
from secrets import token_urlsafe
from urllib.parse import parse_qsl, quote as url_quote, urlencode, urlparse, urlsplit, urlunsplit

from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import RedirectResponse
import logging
import time

from app.rsa_keys import rsa_key_manager
from app.config import get_settings
from app.ehall_client import EhallClient
from app.rate_limit import limiter
from app.schemas import (
    AuthResponse,
    AutoLoginRequest,
    NativeSsoCompleteRequest,
    NativeSsoStartRequest,
    NativeSsoStartResponse,
    ReloginRequest,
    SsoCompleteRequest,
)
from app.school_client import AuthenticationError, SchoolSdkClient

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])
_NATIVE_SSO_CALLBACK_URL = "cn.gzus.pro://sso/callback"


@dataclass(frozen=True)
class PendingLySso:
    return_url: str
    expires_at: float
    verifier_hash: str | None


@dataclass(frozen=True)
class PendingLySsoHandoff:
    ticket: str
    expires_at: float
    verifier_hash: str


@router.get("/public-key")
def get_public_key() -> dict:
    return {
        "publicKey": rsa_key_manager.get_public_key_pem(),
        "keyId": rsa_key_manager.get_key_id(),
    }


def _origin(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}"


def _safe_return_url(return_url: str) -> str:
    settings = get_settings()
    candidate = (return_url or "").strip()
    if not candidate:
        return settings.frontend_base_url
    parsed = urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return settings.frontend_base_url
    if _origin(candidate) == settings.frontend_origin:
        return candidate
    if parsed.hostname in {"localhost", "127.0.0.1"}:
        return candidate
    return settings.frontend_base_url


def _sso_return_url(return_url: str, ticket: str) -> str:
    """将一次性 CAS ticket 传回前端，并覆盖可能残留的旧登录参数。"""
    parsed = urlsplit(return_url)
    query = [(key, value) for key, value in parse_qsl(parsed.query, keep_blank_values=True)
             if key not in {"ssoCode", "ssoError"}]
    query.append(("ssoCode", ticket))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), parsed.fragment))


def _native_sso_return_url(code: str) -> str:
    parsed = urlsplit(_NATIVE_SSO_CALLBACK_URL)
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode({"code": code}), ""))


def _hash_verifier(verifier: str) -> str:
    return sha256(verifier.encode("utf-8")).hexdigest()


def _purge_expired_sso_entries(request: Request, now: float) -> None:
    states: dict[str, PendingLySso] = request.app.state.ly_sso_states
    handoffs: dict[str, PendingLySsoHandoff] = request.app.state.ly_sso_handoffs
    for state, pending in list(states.items()):
        if pending.expires_at <= now:
            del states[state]
    for code, handoff in list(handoffs.items()):
        if handoff.expires_at <= now:
            del handoffs[code]


def _create_cas_sso_url(state: str) -> str:
    settings = get_settings()
    callback = f"{settings.public_api_base_url}/auth/ly/callback"
    callback_with_state = f"{callback}?{urlencode({'state': state})}"
    return f"{settings.cas_login_url}?service={url_quote(callback_with_state, safe='')}"


def _create_pending_sso(
    request: Request,
    return_url: str,
    verifier_hash: str | None,
) -> str:
    settings = get_settings()
    now = time.monotonic()
    _purge_expired_sso_entries(request, now)
    state = token_urlsafe(32)
    request.app.state.ly_sso_states[state] = PendingLySso(
        return_url=return_url,
        expires_at=now + settings.sso_ttl_seconds,
        verifier_hash=verifier_hash,
    )
    return _create_cas_sso_url(state)


def _build_client(request: Request) -> SchoolSdkClient:
    settings = get_settings()
    return SchoolSdkClient(settings.jw_base_url, timeout_seconds=settings.request_timeout_seconds)


def _should_return_jwxt_cookies(request: Request) -> bool:
    return (request.headers.get("x-client-platform") or "").lower() in {"android", "ios"}


@router.get("/ly/start")
def ly_sso_start(return_url: str = "", request: Request = None):
    return RedirectResponse(url=_create_pending_sso(request, _safe_return_url(return_url), None))


@router.post("/ly/native-start", response_model=NativeSsoStartResponse)
@limiter.limit("10/minute")
def ly_native_sso_start(payload: NativeSsoStartRequest, request: Request) -> dict[str, str]:
    authorization_url = _create_pending_sso(
        request,
        _NATIVE_SSO_CALLBACK_URL,
        _hash_verifier(payload.verifier),
    )
    return {"authorizationUrl": authorization_url}


@router.get("/ly/callback")
def ly_sso_callback(ticket: str = "", state: str = "", request: Request = None):
    if not ticket:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 ticket")
    settings = get_settings()
    now = time.monotonic()
    _purge_expired_sso_entries(request, now)
    pending: PendingLySso | None = request.app.state.ly_sso_states.pop(state, None)
    if pending is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="SSO state 无效或已过期")
    if pending.verifier_hash is None:
        return RedirectResponse(url=_sso_return_url(pending.return_url, ticket))
    code = token_urlsafe(32)
    request.app.state.ly_sso_handoffs[code] = PendingLySsoHandoff(
        ticket=ticket,
        expires_at=now + settings.sso_ttl_seconds,
        verifier_hash=pending.verifier_hash,
    )
    return RedirectResponse(url=_native_sso_return_url(code))


@router.post("/ly/complete", response_model=AuthResponse)
def ly_sso_complete(payload: SsoCompleteRequest, request: Request) -> dict:
    return _complete_sso_ticket(payload.sso_code, request)


@router.post("/ly/native-complete", response_model=AuthResponse)
@limiter.limit("10/minute")
def ly_native_sso_complete(payload: NativeSsoCompleteRequest, request: Request) -> dict:
    now = time.monotonic()
    _purge_expired_sso_entries(request, now)
    handoff: PendingLySsoHandoff | None = request.app.state.ly_sso_handoffs.pop(payload.code, None)
    if handoff is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="认证凭证无效或已过期")
    if not compare_digest(handoff.verifier_hash, _hash_verifier(payload.verifier)):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="认证校验失败，请重新登录")
    return _complete_sso_ticket(handoff.ticket, request)


def _complete_sso_ticket(ticket: str, request: Request) -> dict:
    """Complete SSO login by exchanging the CAS service ticket for JWXT cookies.

    The sso_code from the frontend is a CAS Service Ticket, NOT a cookie.
    We must exchange it for actual JWXT session cookies by following the
    service URL redirect chain, then pass those cookies to the SDK.
    """
    import httpx

    sessions = request.app.state.sessions
    settings = get_settings()

    if not ticket:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 SSO 凭证")

    # Step 1: Exchange CAS ticket for JWXT cookies
    service_url = settings.jwxt_sso_service_url
    if "?" in service_url:
        redirect_url = f"{service_url}&ticket={ticket}"
    else:
        redirect_url = f"{service_url}?ticket={ticket}"

    jwxt_cookies = ""
    try:
        with httpx.Client(follow_redirects=True, timeout=settings.cas_login_timeout_seconds) as http_client:
            response = http_client.get(redirect_url)
            response.raise_for_status()
            # Extract cookies for the configured JWXT domain
            jwxt_host = (urlparse(settings.jwxt_sso_service_url).hostname or "jwxt.gzus.edu.cn").lower()
            cookie_parts = []
            seen_keys = set()
            for cookie in http_client.cookies.jar:
                domain = (cookie.domain or "").lower().lstrip(".")
                if not domain:
                    continue
                if jwxt_host == domain or jwxt_host.endswith(f".{domain}"):
                    if cookie.name not in seen_keys:
                        seen_keys.add(cookie.name)
                        cookie_parts.append(f"{cookie.name}={cookie.value}")
            jwxt_cookies = "; ".join(cookie_parts)
    except Exception as exc:
        logger.warning("SSO ticket exchange failed: %s", type(exc).__name__)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="SSO 凭证兑换失败，请重新登录",
        ) from exc

    if not jwxt_cookies:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="SSO 登录未获取到教务系统会话",
        )

    # Step 2: Use the obtained cookies to create a school client session
    client = _build_client(request)
    try:
        student_name = client.login_with_cookies(jwxt_cookies, account="")
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    try:
        info = client.get_info()
        student_id = info.get("studentId")
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="无法确认登录学号，请重新登录",
        ) from exc
    if not isinstance(student_id, str) or not student_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="统一认证未返回有效学号，请重新登录",
        )

    session = sessions.create(client, student_name, student_account=student_id)
    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": student_id,
    }
    if _should_return_jwxt_cookies(request):
        response["jwxtCookies"] = client.get_jwxt_cookies_string()
    return response


@router.post("/relogin", response_model=AuthResponse)
@limiter.limit("10/minute")
def relogin(payload: ReloginRequest, request: Request) -> dict:
    from app.cas_auto_login import CasAutoLogin
    from app.sessions import decrypt_credentials

    settings = get_settings()
    sessions = request.app.state.sessions
    old_session_id = request.headers.get("X-Session-Id")
    if old_session_id:
        old_session = sessions.get(old_session_id, touch=False)
        if old_session is not None and old_session.revoked_at is not None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="账号已在其他设备登录，请重新登录",
            )

    try:
        account, password = decrypt_credentials(
            payload.credential_token,
            settings.credential_encryption_key,
            ttl_seconds=settings.ehall_session_ttl_hours * 3600,
        )
    except Exception as exc:
        raise HTTPException(status_code=401, detail="凭据已失效，请重新登录") from exc

    cas_url = (
        f"{settings.cas_login_url}?service="
        f"{url_quote(settings.jwxt_sso_service_url, safe='')}"
    )
    cas_auto_login = CasAutoLogin(
        cas_url=cas_url,
        ehall_url=settings.ehall_base_url,
        ehall_service_url=settings.ehall_service_url,
        timeout=settings.cas_login_timeout_seconds,
    )
    result = cas_auto_login.auto_login(account, password)
    if result.error:
        raise HTTPException(status_code=401, detail=result.error)

    client = SchoolSdkClient(
        base_url=settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
        httpx_client=result.httpx_client,
    )
    try:
        student_name = client.login_with_cookies(result.cookies, account=result.account)
    except Exception as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    ehall_client = None
    if result.ehall_auth_token or result.ehall_cookies:
        ehall_client = EhallClient(
            base_url=settings.ehall_base_url,
            cookies=result.ehall_cookies or "",
            auth_token=result.ehall_auth_token,
            timeout_seconds=settings.request_timeout_seconds,
        )

    session = sessions.create(
        client, student_name=student_name,
        ehall_client=ehall_client,
        student_account=account,
    )

    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": account,
        "credentialToken": payload.credential_token,
        "ehallCookies": result.ehall_cookies,
        "ehallAuthToken": result.ehall_auth_token,
    }
    if _should_return_jwxt_cookies(request):
        response["jwxtCookies"] = result.cookies
    return response


@router.post("/auto-login", response_model=AuthResponse)
@limiter.limit("10/minute")
def auto_login(payload: AutoLoginRequest, request: Request) -> dict:
    from app.cas_auto_login import CasAutoLogin

    try:
        password = payload.resolve_password()
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    t_total = time.time()
    sessions = request.app.state.sessions
    settings = get_settings()

    cas_url = (
        f"{settings.cas_login_url}?service="
        f"{url_quote(settings.jwxt_sso_service_url, safe='')}"
    )
    cas_auto_login = CasAutoLogin(
        cas_url=cas_url,
        ehall_url=settings.ehall_base_url,
        ehall_service_url=settings.ehall_service_url,
        timeout=settings.cas_login_timeout_seconds,
    )
    t1 = time.time()
    result = cas_auto_login.auto_login(payload.account, password)
    logger.info("[TIMING] cas_auto_login.auto_login: %.2fs", time.time() - t1)

    if result.error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=result.error)

    client = SchoolSdkClient(
        base_url=settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
        httpx_client=result.httpx_client,
    )
    t2 = time.time()
    try:
        student_name = client.login_with_cookies(result.cookies, result.account)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))
    logger.info("[TIMING] login_with_cookies: %.2fs", time.time() - t2)

    ehall_client = None
    if result.ehall_auth_token:
        ehall_client = EhallClient(
            settings.ehall_base_url,
            result.ehall_cookies or "",
            auth_token=result.ehall_auth_token,
            timeout_seconds=settings.request_timeout_seconds,
        )
    elif result.ehall_cookies:
        ehall_client = EhallClient(
            settings.ehall_base_url,
            result.ehall_cookies,
            timeout_seconds=settings.request_timeout_seconds,
        )

    from app.sessions import encrypt_credentials

    cred_token = encrypt_credentials(payload.account, password, settings.credential_encryption_key)

    session = sessions.create(
        client, student_name,
        ehall_client=ehall_client,
        student_account=payload.account,
    )

    logger.info("[TIMING] auto_login endpoint total: %.2fs", time.time() - t_total)
    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": payload.account,
        "credentialToken": cred_token,
        "ehallCookies": result.ehall_cookies,
        "ehallAuthToken": result.ehall_auth_token,
    }
    if _should_return_jwxt_cookies(request):
        response["jwxtCookies"] = result.cookies
    return response


@router.get("/student-info")
def get_student_info(request: Request) -> dict:
    """Async endpoint to fetch student info after login.

    This is called by the client after login completes to avoid blocking
    the login response while fetching detailed student info (which includes
    photo download and can take several seconds).
    """
    sessions = request.app.state.sessions
    session_id = request.headers.get("X-Session-Id")
    if not session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="未登录")
    session = sessions.get(session_id)
    if not session:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期")

    client = session.client
    if not client:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话无效")

    try:
        info = client.get_info()
    except Exception as exc:
        logger.warning("get_student_info failed: %s", exc)
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="获取学生信息失败")

    student_id = info.get("studentId") or None
    return {
        "status": "ok",
        "studentId": student_id,
        "info": info,
    }


@router.post("/logout")
def logout(request: Request) -> dict:
    sessions = request.app.state.sessions
    session_id = request.headers.get("X-Session-Id")
    if session_id:
        sessions.remove(session_id)
    return {"status": "ok"}
