from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from urllib.parse import quote as url_quote
import uuid

from app.config import get_settings
from app.ehall_client import EhallClient
from app.schemas import AuthResponse, AutoLoginRequest, CaptchaRequest, LoginRequest, ReloginRequest, SsoCompleteRequest
from app.school_client import AuthenticationError, CaptchaRequired, SchoolSdkClient

router = APIRouter(prefix="/auth", tags=["auth"])


class LySsoStartRequest(BaseModel):
    return_url: str = ""


def _build_client(request: Request) -> SchoolSdkClient:
    settings = get_settings()
    return SchoolSdkClient(settings.jw_base_url, timeout_seconds=settings.request_timeout_seconds)


@router.post("/login", response_model=AuthResponse)
def login(payload: LoginRequest, request: Request) -> dict:
    client = _build_client(request)
    sessions = request.app.state.sessions
    pending_captcha = request.app.state.pending_captcha

    try:
        student_name = client.login(payload.account, payload.password)
    except CaptchaRequired as exc:
        token = exc.challenge.token or "captcha"
        pending_captcha[token] = client
        return {
            "status": "captcha_required",
            "captchaToken": token,
            "captchaImage": exc.challenge.image or "",
        }
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    session = sessions.create(client, student_name or payload.account)
    student_id = _try_get_student_id(client)
    return {"status": "ok", "sessionId": session.id, "studentName": student_name, "studentId": student_id}


def _try_get_student_id(client) -> str | None:
    try:
        info = client.get_info()
        if isinstance(info, dict):
            return info.get("studentId") or info.get("student_id") or info.get("xh")
    except Exception:
        pass
    return None


@router.post("/captcha", response_model=AuthResponse)
def submit_captcha(payload: CaptchaRequest, request: Request) -> dict:
    sessions = request.app.state.sessions
    pending_captcha = request.app.state.pending_captcha

    client = pending_captcha.pop(payload.captcha_token, None)
    if client is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="验证码会话已过期")

    try:
        student_name = client.submit_captcha(payload.code)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    session = sessions.create(client, student_name)
    student_id = _try_get_student_id(client)
    return {"status": "ok", "sessionId": session.id, "studentName": student_name, "studentId": student_id}


@router.get("/ly/start")
def ly_sso_start(return_url: str = "", request: Request = None):
    settings = get_settings()
    state = uuid.uuid4().hex[:16]
    request.app.state.ly_sso_states[state] = return_url
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
    request.app.state.ly_sso_proxy_granting_tickets[state] = ticket
    return_url = request.app.state.ly_sso_states.pop(state, settings.frontend_base_url)
    return RedirectResponse(url=return_url)


@router.post("/ly/complete", response_model=AuthResponse)
def ly_sso_complete(payload: SsoCompleteRequest, request: Request) -> dict:
    sessions = request.app.state.sessions
    ticket = payload.sso_code

    client = _build_client(request)
    try:
        student_name = client.login_with_cookies(None, ticket)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    session = sessions.create(client, student_name)
    student_id = _try_get_student_id(client)
    return {"status": "ok", "sessionId": session.id, "studentName": student_name, "studentId": student_id}


@router.post("/relogin", response_model=AuthResponse)
def relogin(payload: ReloginRequest, request: Request) -> dict:
    from app.cas_auto_login import CasAutoLogin
    from app.sessions import decrypt_credentials

    settings = get_settings()
    sessions = request.app.state.sessions

    try:
        account, password = decrypt_credentials(
            payload.credential_token, settings.credential_encryption_key
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
        timeout=settings.request_timeout_seconds,
    )
    result = cas_auto_login.auto_login(account, password)
    if result.error:
        raise HTTPException(status_code=401, detail=result.error)

    client = SchoolSdkClient(base_url=settings.jw_base_url, timeout_seconds=settings.request_timeout_seconds)
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

    session = sessions.create(client, student_name=student_name, ehall_client=ehall_client)
    student_id = _try_get_student_id(client)

    return {
        "status": "ok",
        "sessionId": session.id,
        "studentName": student_name,
        "studentId": student_id,
        "credentialToken": payload.credential_token,
    }


@router.post("/auto-login", response_model=AuthResponse)
def auto_login(payload: AutoLoginRequest, request: Request) -> dict:
    from app.cas_auto_login import CasAutoLogin

    sessions = request.app.state.sessions
    settings = get_settings()

    cas_url = (
        f"{settings.cas_login_url}?service="
        f"{url_quote(settings.jwxt_sso_service_url, safe='')}"
    )
    cas_auto_login = CasAutoLogin(
        cas_url=cas_url,
        ehall_url=settings.ehall_base_url,
        timeout=settings.request_timeout_seconds,
    )
    result = cas_auto_login.auto_login(payload.account, payload.password)

    if result.error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=result.error)

    client = _build_client(request)
    try:
        student_name = client.login_with_cookies(result.cookies, result.account)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

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

    session = sessions.create(client, student_name, ehall_client=ehall_client)
    student_id = _try_get_student_id(client)

    from app.sessions import encrypt_credentials

    cred_token = encrypt_credentials(payload.account, payload.password, settings.credential_encryption_key)
    return {"status": "ok", "sessionId": session.id, "studentName": student_name, "studentId": student_id, "credentialToken": cred_token}


@router.post("/logout")
def logout(request: Request) -> dict:
    sessions = request.app.state.sessions
    session_id = request.headers.get("X-Session-Id")
    if session_id:
        sessions.remove(session_id)
    return {"status": "ok"}
