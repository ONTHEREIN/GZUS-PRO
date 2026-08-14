from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import httpx

from app.ehall_client import EhallClient
from app.routes.deps import SESSION_IDLE_STALE_THRESHOLD, _inject_worker_cookies, require_session
from app.school_client import SchoolSdkClient
from app.sessions import AppSession, SessionStore


def _request(
    store: SessionStore,
    path: str,
    method: str,
    headers: dict[str, str],
) -> SimpleNamespace:
    return SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(sessions=store)),
        url=SimpleNamespace(path=path),
        method=method,
        headers=headers,
    )


def test_worker_cookie_injection_updates_school_and_ehall_connectors() -> None:
    school_http = httpx.Client()
    school = SchoolSdkClient(
        "https://jwxt.gzus.edu.cn/jwglxt",
        httpx_client=school_http,
    )
    ehall = EhallClient(
        "https://ehall.gzus.edu.cn",
        "customsid=old",
        auth_token="old-token",
        timeout_seconds=6,
    )
    ehall_http = ehall._get_http_client()
    session = AppSession(id="session-id", client=school, ehall_client=ehall)
    request = SimpleNamespace(
        headers={
            "X-Worker-Auth": "1",
            "Cookie": "route=edge; JSESSIONID=fresh",
            "X-Student-Account": "20240001",
            "X-Ehall-Cookies": "customsid=new; Authorization=new-token",
        }
    )

    try:
        assert _inject_worker_cookies(session, request) is True
        school_cookies = {cookie.name: cookie.value for cookie in school_http.cookies.jar}
        assert school_cookies["JSESSIONID"] == "fresh"
        assert school._account == "20240001"
        assert ehall.cookie_header == "customsid=new; Authorization=new-token"
        assert ehall_http.cookies.get("customsid") == "new"
        assert ehall_http.cookies.get("Authorization") == "new-token"
    finally:
        school_http.close()
        ehall.close()


def test_worker_cookies_recover_missing_school_connector() -> None:
    session = AppSession(id="session-id", client=None)
    request = SimpleNamespace(
        headers={
            "X-Worker-Auth": "1",
            "Cookie": "route=edge; JSESSIONID=recovered",
            "X-Student-Account": "20240002",
        }
    )

    assert _inject_worker_cookies(session, request) is True
    assert isinstance(session.client, SchoolSdkClient)
    assert session.client._account == "20240002"


def test_worker_cookie_injection_keeps_idle_session_usable() -> None:
    school_http = httpx.Client()
    school = SchoolSdkClient(
        "https://jwxt.gzus.edu.cn/jwglxt",
        httpx_client=school_http,
    )
    store = SessionStore(ttl_seconds=7200)
    session = store.create(school, student_account="20240003")
    session.last_active_at = (
        datetime.now(timezone.utc).replace(tzinfo=None)
        - SESSION_IDLE_STALE_THRESHOLD
        - timedelta(seconds=1)
    )
    request = _request(
        store,
        "/grades",
        "GET",
        {
            "X-Worker-Auth": "1",
            "Cookie": "JSESSIONID=fresh-idle-session",
            "X-Student-Account": "20240003",
        },
    )

    try:
        resolved = require_session(request, x_session_id=session.id)
        assert resolved.id == session.id
        cookie_values = {
            cookie.value
            for cookie in school_http.cookies.jar
            if cookie.name == "JSESSIONID"
        }
        assert cookie_values == {"fresh-idle-session"}
    finally:
        school_http.close()
