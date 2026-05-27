from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from secrets import token_urlsafe
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse, urlunparse
from xml.etree import ElementTree

import httpx
from fastapi import APIRouter, Header, HTTPException, Query, Request, status
from fastapi.responses import PlainTextResponse, RedirectResponse

from app.config import get_settings
from app.schemas import (
    AuthResponse,
    CaptchaRequest,
    LoginRequest,
    MobileCookieLoginRequest,
    SsoCompleteRequest,
)
from app.school_client import AuthenticationError, CaptchaRequired, SchoolSdkClient

router = APIRouter(prefix="/auth", tags=["auth"])


@dataclass
class LySsoState:
    return_url: str
    expires_at: datetime


@dataclass
class LySsoResult:
    client: SchoolSdkClient
    student_name: str | None
    expires_at: datetime


@dataclass
class LyProxyGrantingTicket:
    pgt_id: str
    expires_at: datetime


@router.post("/login", response_model=AuthResponse)
def login(payload: LoginRequest, request: Request) -> AuthResponse:
    settings = get_settings()
    client = SchoolSdkClient(settings.jw_base_url, settings.request_timeout_seconds)
    try:
        student_name = client.login(payload.account, payload.password)
    except CaptchaRequired as exc:
        token = exc.challenge.token or token_urlsafe(24)
        request.app.state.pending_captcha[token] = exc.challenge.client
        return AuthResponse(
            status="captcha_required",
            captchaToken=token,
            captchaImage=exc.challenge.image,
        )
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    session = request.app.state.sessions.create(client, student_name)
    return AuthResponse(status="ok", sessionId=session.id, studentName=student_name)


@router.get("/ly/start")
def ly_sso_start(
    request: Request, return_url: str | None = Query(default=None)
) -> RedirectResponse:
    settings = get_settings()
    _cleanup_sso_state(request)
    safe_return_url = _validated_return_url(return_url, settings.frontend_base_url)
    if _is_local_callback_base(settings.public_api_base_url):
        return _sso_error_redirect(
            safe_return_url,
            "联奕单点登录回调地址未在认证平台登记，请配置 PUBLIC_API_BASE_URL 为已登记的公网地址",
        )
    state = token_urlsafe(32)
    request.app.state.ly_sso_states[state] = LySsoState(
        return_url=safe_return_url,
        expires_at=datetime.now(UTC) + timedelta(seconds=settings.sso_ttl_seconds),
    )
    service = _cas_service_url(settings, state)
    login_url = _url_with_query(settings.cas_login_url, {"service": service})
    return RedirectResponse(login_url, status_code=status.HTTP_303_SEE_OTHER)


@router.get("/ly/proxy-callback")
def ly_sso_proxy_callback(
    request: Request, pgtIou: str | None = None, pgtId: str | None = None
) -> PlainTextResponse:
    settings = get_settings()
    _cleanup_sso_state(request)
    if pgtIou and pgtId:
        request.app.state.ly_sso_proxy_granting_tickets[pgtIou] = LyProxyGrantingTicket(
            pgt_id=pgtId,
            expires_at=datetime.now(UTC) + timedelta(seconds=settings.sso_ttl_seconds),
        )
    return PlainTextResponse("ok")


@router.get("/ly/callback")
def ly_sso_callback(
    request: Request,
    state: str | None = Query(default=None),
    ticket: str | None = Query(default=None),
) -> RedirectResponse:
    settings = get_settings()
    _cleanup_sso_state(request)
    sso_state = request.app.state.ly_sso_states.pop(state or "", None)
    if sso_state is None:
        return _sso_error_redirect(settings.frontend_base_url, "单点登录会话不存在或已过期")
    if not ticket:
        return _sso_error_redirect(sso_state.return_url, "联奕单点登录未返回有效票据")

    try:
        proxy_ticket, account = _get_proxy_ticket(request, settings, state or "", ticket)
        cookies = _fetch_jwxt_cookies(settings, proxy_ticket)
        client = SchoolSdkClient(settings.jw_base_url, settings.request_timeout_seconds)
        student_name = client.login_with_cookies(cookies, account=account or "sso-account")
    except SsoFlowError as exc:
        return _sso_error_redirect(sso_state.return_url, str(exc))
    except AuthenticationError as exc:
        return _sso_error_redirect(sso_state.return_url, str(exc))

    sso_code = token_urlsafe(32)
    request.app.state.ly_sso_results[sso_code] = LySsoResult(
        client=client,
        student_name=student_name,
        expires_at=datetime.now(UTC) + timedelta(seconds=settings.sso_ttl_seconds),
    )
    return RedirectResponse(
        _url_with_query(sso_state.return_url, {"ssoCode": sso_code}),
        status_code=status.HTTP_303_SEE_OTHER,
    )


@router.post("/ly/complete", response_model=AuthResponse)
def ly_sso_complete(payload: SsoCompleteRequest, request: Request) -> AuthResponse:
    _cleanup_sso_state(request)
    result = request.app.state.ly_sso_results.pop(payload.sso_code, None)
    if result is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="单点登录结果不存在或已过期，请重新登录",
        )
    session = request.app.state.sessions.create(result.client, result.student_name)
    return AuthResponse(status="ok", sessionId=session.id, studentName=result.student_name)


@router.post("/mobile-cookie-login", response_model=AuthResponse)
def mobile_cookie_login(payload: MobileCookieLoginRequest, request: Request) -> AuthResponse:
    if not payload.cookies.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="未获取到教务系统 cookie",
        )
    settings = get_settings()
    client = SchoolSdkClient(settings.jw_base_url, settings.request_timeout_seconds)
    try:
        student_name = client.login_with_cookies(payload.cookies, payload.account)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    session = request.app.state.sessions.create(client, student_name)
    return AuthResponse(status="ok", sessionId=session.id, studentName=student_name)


@router.post("/captcha", response_model=AuthResponse)
def captcha(payload: CaptchaRequest, request: Request) -> AuthResponse:
    client = request.app.state.pending_captcha.pop(payload.captcha_token, None)
    if client is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="验证码会话不存在或已过期"
        )
    try:
        student_name = client.submit_captcha(payload.code)
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    session = request.app.state.sessions.create(client, student_name)
    return AuthResponse(status="ok", sessionId=session.id, studentName=student_name)


@router.post("/logout")
def logout(
    request: Request, x_session_id: str | None = Header(default=None, alias="X-Session-Id")
) -> dict[str, str]:
    if x_session_id:
        request.app.state.sessions.delete(x_session_id)
    return {"status": "ok"}


class SsoFlowError(RuntimeError):
    pass


def _cleanup_sso_state(request: Request) -> None:
    now = datetime.now(UTC)
    for name in ("ly_sso_states", "ly_sso_results", "ly_sso_proxy_granting_tickets"):
        store = getattr(request.app.state, name, {})
        for key, value in list(store.items()):
            if value.expires_at <= now:
                store.pop(key, None)


def _cas_service_url(settings, state: str) -> str:
    return _url_with_query(
        f"{settings.public_api_base_url.rstrip('/')}/auth/ly/callback",
        {"state": state},
    )


def _cas_endpoint(login_url: str, endpoint: str) -> str:
    base = login_url.rsplit("/", 1)[0] + "/"
    return urljoin(base, endpoint)


def _get_proxy_ticket(
    request: Request, settings, state: str, ticket: str
) -> tuple[str, str | None]:
    service_url = _cas_service_url(settings, state)
    pgt_url = f"{settings.public_api_base_url.rstrip('/')}/auth/ly/proxy-callback"
    try:
        with httpx.Client(
            timeout=settings.request_timeout_seconds, follow_redirects=True
        ) as client:
            validate = client.get(
                _cas_endpoint(settings.cas_login_url, "serviceValidate"),
                params={"service": service_url, "ticket": ticket, "pgtUrl": pgt_url},
            )
            validate.raise_for_status()
            root = ElementTree.fromstring(validate.text)
            failure = _xml_text(root, "authenticationFailure")
            if failure:
                raise SsoFlowError("联奕单点登录验证失败")
            pgt_iou = _xml_text(root, "proxyGrantingTicket")
            account = _xml_text(root, "user")
            if not pgt_iou:
                raise SsoFlowError("CAS 未返回 ProxyGrantingTicket")
            pgt = request.app.state.ly_sso_proxy_granting_tickets.pop(pgt_iou, None)
            if not pgt:
                raise SsoFlowError("ProxyTicket 获取失败")
            proxy = client.get(
                _cas_endpoint(settings.cas_login_url, "proxy"),
                params={"pgt": pgt.pgt_id, "targetService": settings.jwxt_sso_service_url},
            )
            proxy.raise_for_status()
            proxy_root = ElementTree.fromstring(proxy.text)
            proxy_failure = _xml_text(proxy_root, "proxyFailure")
            if proxy_failure:
                raise SsoFlowError("CAS ProxyTicket 换取失败")
            proxy_ticket = _xml_text(proxy_root, "proxyTicket")
            if not proxy_ticket:
                raise SsoFlowError("CAS 未返回 JWXT ProxyTicket")
            return proxy_ticket, account
    except SsoFlowError:
        raise
    except httpx.HTTPError as exc:
        raise SsoFlowError("联奕单点登录服务请求异常") from exc
    except ElementTree.ParseError as exc:
        raise SsoFlowError("联奕单点登录响应解析失败") from exc


def _fetch_jwxt_cookies(settings, proxy_ticket: str) -> dict[str, str]:
    try:
        with httpx.Client(
            timeout=settings.request_timeout_seconds, follow_redirects=True
        ) as client:
            response = client.get(settings.jwxt_sso_service_url, params={"ticket": proxy_ticket})
            response.raise_for_status()
            cookies = dict(client.cookies.items())
    except httpx.HTTPError as exc:
        raise SsoFlowError("教务系统自动跳转异常") from exc
    if not cookies:
        raise SsoFlowError("未获取到教务系统 cookie")
    return cookies


def _xml_text(root: ElementTree.Element, local_name: str) -> str | None:
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] == local_name and element.text:
            return element.text.strip()
    return None


def _validated_return_url(value: str | None, frontend_base_url: str) -> str:
    fallback = frontend_base_url.rstrip("/")
    if not value:
        return fallback
    parsed_value = urlparse(value)
    parsed_allowed = urlparse(fallback)
    if (
        parsed_value.scheme in ("http", "https")
        and parsed_value.scheme == parsed_allowed.scheme
        and parsed_value.netloc == parsed_allowed.netloc
    ):
        return value
    return fallback


def _is_local_callback_base(value: str) -> bool:
    hostname = urlparse(value).hostname
    return hostname in {"localhost", "127.0.0.1", "::1"}


def _sso_error_redirect(return_url: str, message: str) -> RedirectResponse:
    return RedirectResponse(
        _url_with_query(return_url, {"ssoError": message}),
        status_code=status.HTTP_303_SEE_OTHER,
    )


def _url_with_query(url: str, updates: dict[str, str]) -> str:
    parsed = urlparse(url)
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query.update(updates)
    return urlunparse(parsed._replace(query=urlencode(query)))
