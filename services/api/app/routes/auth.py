from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from urllib.parse import quote as url_quote, urlparse
import logging
import time
import uuid

from app.rsa_keys import rsa_key_manager
from app.config import get_settings
from app.ehall_client import EhallClient
from app.rate_limit import limiter
from app.schemas import AuthResponse, AutoLoginRequest, CaptchaRequest, LoginRequest, ReloginRequest, SsoCompleteRequest
from app.school_client import AuthenticationError, CaptchaRequired, SchoolSdkClient

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.get("/public-key")
def get_public_key() -> dict:
    return {
        "publicKey": rsa_key_manager.get_public_key_pem(),
        "keyId": rsa_key_manager.get_key_id(),
    }


class LySsoStartRequest(BaseModel):
    return_url: str = ""


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


def _build_client(request: Request) -> SchoolSdkClient:
    settings = get_settings()
    return SchoolSdkClient(settings.jw_base_url, timeout_seconds=settings.request_timeout_seconds)


def _should_return_jwxt_cookies(request: Request) -> bool:
    return (request.headers.get("x-client-platform") or "").lower() in {"android", "ios"}


@router.post("/login", response_model=AuthResponse)
@limiter.limit("10/minute")
def login(payload: LoginRequest, request: Request) -> dict:
    client = _build_client(request)
    sessions = request.app.state.sessions
    pending_captcha = request.app.state.pending_captcha

    try:
        password = payload.resolve_password()
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    try:
        student_name = client.login(payload.account, password)
    except CaptchaRequired as exc:
        token = exc.challenge.token or "captcha"
        pending_captcha[token] = (client, payload.account)
        return {
            "status": "captcha_required",
            "captchaToken": token,
            "captchaImage": exc.challenge.image or "",
        }
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    session = sessions.create(
        client,
        student_name or payload.account,
        student_account=payload.account,
    )
    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": None,
    }
    if _should_return_jwxt_cookies(request):
        response["jwxtCookies"] = client.get_jwxt_cookies_string()
    return response


def _try_get_student_id(client) -> str | None:
    try:
        info = client.get_info()
        if isinstance(info, dict):
            return info.get("studentId") or info.get("student_id") or info.get("xh")
    except Exception:
        pass
    return None


@router.post("/captcha", response_model=AuthResponse)
@limiter.limit("10/minute")
def submit_captcha(payload: CaptchaRequest, request: Request) -> dict:
    sessions = request.app.state.sessions
    pending_captcha = request.app.state.pending_captcha

    pending = pending_captcha.pop(payload.captcha_token, None)
    if isinstance(pending, tuple):
        client, account = pending
    else:
        client, account = pending, None
    if client is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="验证码会话已过期")

    try:
        student_name = client.submit_captcha(payload.code)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    session = sessions.create(client, student_name, student_account=account)
    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": None,
    }
    if _should_return_jwxt_cookies(request):
        response["jwxtCookies"] = client.get_jwxt_cookies_string()
    return response


@router.get("/ly/start")
def ly_sso_start(return_url: str = "", request: Request = None):
    settings = get_settings()
    state = uuid.uuid4().hex
    request.app.state.ly_sso_states[state] = _safe_return_url(return_url)
    callback = f"{settings.public_api_base_url}/auth/ly/callback"
    encoded_callback = url_quote(callback, safe="")
    sso_url = (
        f"{settings.cas_login_url}"
        f"?service={encoded_callback}"
        f"&state={state}"
    )
    return RedirectResponse(url=sso_url)


@router.get("/ly/callback")
def ly_sso_callback(ticket: str = "", state: str = "", request: Request = None):
    if not ticket:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少 ticket")
    settings = get_settings()
    if not state or state not in request.app.state.ly_sso_states:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="SSO state 无效")
    return_url = request.app.state.ly_sso_states.pop(state, settings.frontend_base_url)
    return RedirectResponse(url=return_url)


@router.post("/ly/complete", response_model=AuthResponse)
def ly_sso_complete(payload: SsoCompleteRequest, request: Request) -> dict:
    """Complete SSO login by exchanging the CAS service ticket for JWXT cookies.

    The sso_code from the frontend is a CAS Service Ticket, NOT a cookie.
    We must exchange it for actual JWXT session cookies by following the
    service URL redirect chain, then pass those cookies to the SDK.
    """
    import httpx

    sessions = request.app.state.sessions
    settings = get_settings()
    ticket = payload.sso_code

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
            # Extract cookies for the JWXT domain
            jwxt_host = "jwxt.seig.edu.cn"
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

    session = sessions.create(client, student_name)
    return {"status": "ok", "sessionId": session.id, "studentName": student_name, "studentId": None}


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

    # Generate a fresh Fernet credential token for server-side auto-relogin.
    # The frontend's credential_token may be AES-GCM (from Worker), which
    # Vercel cannot decrypt.  We need our own Fernet token stored in the session.
    from app.sessions import encrypt_credentials as _encrypt_creds
    fernet_token = _encrypt_creds(account, password, settings.credential_encryption_key)

    session = sessions.create(
        client, student_name=student_name,
        ehall_client=ehall_client,
        encrypted_credentials=fernet_token,
        student_account=account,
    )

    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": None,
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
        encrypted_credentials=cred_token,
        student_account=payload.account,
    )

    logger.info("[TIMING] auto_login endpoint total: %.2fs", time.time() - t_total)
    response = {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": None,
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
