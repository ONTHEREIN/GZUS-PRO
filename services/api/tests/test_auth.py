from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient

from app.cas_auto_login import CasLoginResult
from app.config import get_settings
from app.main import create_app
from app.routes import auth as auth_routes
from app.sessions import (
    credential_fingerprint,
    decrypt_credential_payload,
    decrypt_credentials,
    encrypt_credentials,
)


class SuccessfulCasConnector:
    def __init__(
        self,
        cas_url: str,
        ehall_url: str,
        ehall_service_url: str,
        timeout: int,
    ) -> None:
        assert cas_url.startswith("https://cas.gzus.edu.cn/")
        assert ehall_url == "https://ehall.gzus.edu.cn"
        assert ehall_service_url == "http://ehall.gzus.edu.cn/shiro-cas"
        assert timeout == 60

    def auto_login(self, account: str, password: str) -> CasLoginResult:
        assert password == "auto-login-password"
        return CasLoginResult(
            account=account,
            cookies="JSESSIONID=auto-login-session",
        )


class CookieSchoolConnector:
    def __init__(self, base_url: str, timeout_seconds: int, httpx_client: object | None) -> None:
        assert base_url == get_settings().jw_base_url
        assert timeout_seconds == get_settings().request_timeout_seconds
        assert httpx_client is None
        self._account: str | None = None
        self._cookies = ""

    def login_with_cookies(self, cookies: str, account: str) -> str:
        self._account = account
        self._cookies = cookies
        return "自动登录学生"

    def get_jwxt_cookies_string(self) -> str:
        return self._cookies

    def logout(self) -> None:
        return None


def test_sso_state_allows_frontend_redirect_once() -> None:
    app = create_app()
    client = TestClient(app)
    return_url = "https://app.example.test/grades?term=2"

    start_response = client.get(
        "/auth/ly/start",
        params={"return_url": return_url},
        follow_redirects=False,
    )

    assert start_response.status_code in {302, 307}
    sso_url = urlparse(start_response.headers["location"])
    service_url = parse_qs(sso_url.query)["service"][0]
    state = parse_qs(urlparse(service_url).query)["state"][0]
    assert app.state.ly_sso_states[state].return_url == return_url

    callback_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-1", "state": state},
        follow_redirects=False,
    )
    assert callback_response.status_code in {302, 307}
    callback_url = urlparse(callback_response.headers["location"])
    assert callback_url.scheme == "https"
    assert callback_url.netloc == "app.example.test"
    assert parse_qs(callback_url.query) == {"term": ["2"], "ssoCode": ["ST-1"]}
    assert state not in app.state.ly_sso_states

    replay_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-1", "state": state},
        follow_redirects=False,
    )
    assert replay_response.status_code == 400
    assert replay_response.json()["detail"] == "SSO state 无效或已过期"


def test_native_sso_handoff_hides_ticket_and_requires_verifier(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    client = TestClient(app)
    verifier = "v" * 43
    monkeypatch.setattr(
        auth_routes,
        "_complete_sso_ticket",
        lambda ticket, request: {
            "status": "ok",
            "sessionId": "native-session",
            "studentName": ticket,
            "studentId": "20240001",
        },
    )

    start_response = client.post("/auth/ly/native-start", json={"verifier": verifier})

    assert start_response.status_code == 200
    service_url = parse_qs(
        urlparse(start_response.json()["authorizationUrl"]).query
    )["service"][0]
    state = parse_qs(urlparse(service_url).query)["state"][0]
    callback_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-native-ticket", "state": state},
        follow_redirects=False,
    )

    callback_url = urlparse(callback_response.headers["location"])
    assert callback_url.scheme == "cn.gzus.pro"
    assert callback_url.netloc == "sso"
    assert callback_url.path == "/callback"
    assert "ST-native-ticket" not in callback_response.headers["location"]
    code = parse_qs(callback_url.query)["code"][0]

    wrong_verifier_response = client.post(
        "/auth/ly/native-complete",
        json={"code": code, "verifier": "x" * 43},
    )
    assert wrong_verifier_response.status_code == 401

    second_start_response = client.post("/auth/ly/native-start", json={"verifier": verifier})
    second_service_url = parse_qs(
        urlparse(second_start_response.json()["authorizationUrl"]).query
    )["service"][0]
    second_state = parse_qs(urlparse(second_service_url).query)["state"][0]
    second_callback_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-native-ticket", "state": second_state},
        follow_redirects=False,
    )
    second_code = parse_qs(urlparse(second_callback_response.headers["location"]).query)["code"][0]
    complete_response = client.post(
        "/auth/ly/native-complete",
        json={"code": second_code, "verifier": verifier},
    )
    assert complete_response.status_code == 200
    assert complete_response.json()["studentName"] == "ST-native-ticket"

    replay_response = client.post(
        "/auth/ly/native-complete",
        json={"code": second_code, "verifier": verifier},
    )
    assert replay_response.status_code == 401


def test_expired_sso_state_and_handoff_are_rejected() -> None:
    app = create_app()
    client = TestClient(app)
    verifier = "v" * 43

    start_response = client.post("/auth/ly/native-start", json={"verifier": verifier})
    service_url = parse_qs(
        urlparse(start_response.json()["authorizationUrl"]).query
    )["service"][0]
    state = parse_qs(urlparse(service_url).query)["state"][0]
    pending = app.state.ly_sso_states[state]
    app.state.ly_sso_states[state] = auth_routes.PendingLySso(
        return_url=pending.return_url,
        expires_at=0,
        verifier_hash=pending.verifier_hash,
    )

    expired_state_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-expired", "state": state},
        follow_redirects=False,
    )
    assert expired_state_response.status_code == 400

    second_start_response = client.post("/auth/ly/native-start", json={"verifier": verifier})
    second_service_url = parse_qs(
        urlparse(second_start_response.json()["authorizationUrl"]).query
    )["service"][0]
    second_state = parse_qs(urlparse(second_service_url).query)["state"][0]
    callback_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-expired", "state": second_state},
        follow_redirects=False,
    )
    code = parse_qs(urlparse(callback_response.headers["location"]).query)["code"][0]
    handoff = app.state.ly_sso_handoffs[code]
    app.state.ly_sso_handoffs[code] = auth_routes.PendingLySsoHandoff(
        ticket=handoff.ticket,
        expires_at=0,
        verifier_hash=handoff.verifier_hash,
    )

    expired_handoff_response = client.post(
        "/auth/ly/native-complete",
        json={"code": code, "verifier": verifier},
    )
    assert expired_handoff_response.status_code == 401


def test_auto_login_creates_reusable_credential_and_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("app.cas_auto_login.CasAutoLogin", SuccessfulCasConnector)
    monkeypatch.setattr(auth_routes, "SchoolSdkClient", CookieSchoolConnector)
    app = create_app()
    client = TestClient(app)

    response = client.post(
        "/auth/auto-login",
        json={"account": "20240004", "password": "auto-login-password"},
        headers={"X-Client-Platform": "android"},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["studentName"] == "自动登录学生"
    assert data["studentId"] == "20240004"
    assert data["jwxtCookies"] == "JSESSIONID=auto-login-session"
    assert decrypt_credentials(
        data["credentialToken"],
        get_settings().credential_encryption_key,
    ) == ("20240004", "auto-login-password")
    session = app.state.sessions.get(data["sessionId"], touch=False)
    assert session is not None
    assert session.student_account == "20240004"
    account, password, credential_id = decrypt_credential_payload(
        data["credentialToken"], get_settings().credential_encryption_key
    )
    assert (account, password) == ("20240004", "auto-login-password")
    assert credential_id is not None
    assert session.credential_fingerprint == credential_fingerprint(credential_id)


def test_relogin_upgrades_legacy_credential_and_rotates_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("app.cas_auto_login.CasAutoLogin", SuccessfulCasConnector)
    monkeypatch.setattr(auth_routes, "SchoolSdkClient", CookieSchoolConnector)
    app = create_app()
    client = TestClient(app)
    legacy_token = encrypt_credentials(
        "20240004", "auto-login-password", get_settings().credential_encryption_key
    )

    response = client.post("/auth/relogin", json={"credentialToken": legacy_token})

    assert response.status_code == 200
    account, password, credential_id = decrypt_credential_payload(
        response.json()["credentialToken"], get_settings().credential_encryption_key
    )
    assert (account, password) == ("20240004", "auto-login-password")
    assert credential_id is not None


def test_relogin_preserves_credential_on_transient_cas_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class UnavailableCasConnector:
        def __init__(self, **_kwargs: object) -> None:
            pass

        def auto_login(self, account: str, password: str) -> CasLoginResult:
            return CasLoginResult(account=account, cookies="", error="CAS 暂不可用", error_status=503)

    monkeypatch.setattr("app.cas_auto_login.CasAutoLogin", UnavailableCasConnector)
    client = TestClient(create_app())
    token = encrypt_credentials(
        "20240004", "auto-login-password", get_settings().credential_encryption_key
    )

    response = client.post("/auth/relogin", json={"credentialToken": token})

    assert response.status_code == 503
    assert response.json()["detail"] == "CAS 暂不可用"


def test_relogin_rejects_invalid_credential_before_cas_request() -> None:
    client = TestClient(create_app())

    response = client.post(
        "/auth/relogin",
        json={"credentialToken": "invalid-token"},
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "凭据已失效，请重新登录"
