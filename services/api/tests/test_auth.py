from urllib.parse import parse_qs, urlparse

import pytest
from fastapi import Request
from fastapi.testclient import TestClient

from app.cas_auto_login import CasLoginResult
from app.config import get_settings
from app.main import create_app
from app.routes import auth as auth_routes
from app.school_client import AuthenticationError, CaptchaChallenge, CaptchaRequired
from app.sessions import decrypt_credentials


class SuccessfulSchoolConnector:
    def __init__(self) -> None:
        self._account: str | None = None

    def login(self, account: str, password: str) -> str:
        assert password == "correct-password"
        self._account = account
        return "测试学生"

    def get_jwxt_cookies_string(self) -> str:
        return "JSESSIONID=login-session"

    def get_info(self) -> dict[str, str]:
        return {"studentId": "20240001", "name": "测试学生"}

    def logout(self) -> None:
        return None


class CaptchaSchoolConnector:
    def __init__(self) -> None:
        self._account: str | None = None

    def login(self, account: str, password: str) -> str:
        assert password == "captcha-password"
        self._account = account
        challenge = CaptchaChallenge(
            token="captcha-token",
            image="data:image/png;base64,Y2FwdGNoYQ==",
            client=self,
        )
        raise CaptchaRequired(challenge)

    def submit_captcha(self, code: str) -> str:
        assert code == "1234"
        return "验证码学生"

    def get_jwxt_cookies_string(self) -> str:
        return "JSESSIONID=captcha-session"

    def logout(self) -> None:
        return None


class RejectingSchoolConnector:
    def login(self, account: str, password: str) -> str:
        raise AuthenticationError(f"账号 {account} 登录失败")


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


def test_login_student_info_and_logout_lifecycle(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    school = SuccessfulSchoolConnector()

    def build_client(request: Request) -> SuccessfulSchoolConnector:
        assert request.url.path == "/auth/login"
        return school

    monkeypatch.setattr(auth_routes, "_build_client", build_client)
    monkeypatch.setattr("app.sessions.time.sleep", lambda _seconds: None)
    client = TestClient(app)

    login_response = client.post(
        "/auth/login",
        json={"account": "20240001", "password": "correct-password"},
        headers={"X-Client-Platform": "android"},
    )

    assert login_response.status_code == 200
    login_data = login_response.json()
    assert login_data["studentName"] == "测试学生"
    assert login_data["jwxtCookies"] == "JSESSIONID=login-session"
    session_id = login_data["sessionId"]
    session = app.state.sessions.get(session_id, touch=False)
    assert session is not None
    assert session.student_account == "20240001"

    info_response = client.get(
        "/auth/student-info",
        headers={"X-Session-Id": session_id},
    )
    assert info_response.status_code == 200
    assert info_response.json()["studentId"] == "20240001"

    logout_response = client.post(
        "/auth/logout",
        headers={"X-Session-Id": session_id},
    )
    assert logout_response.json() == {"status": "ok"}
    assert app.state.sessions.get(session_id, touch=False) is None


def test_login_captcha_preserves_account_and_returns_mobile_cookies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    school = CaptchaSchoolConnector()

    def build_client(request: Request) -> CaptchaSchoolConnector:
        assert request.url.path == "/auth/login"
        return school

    monkeypatch.setattr(auth_routes, "_build_client", build_client)
    client = TestClient(app)

    login_response = client.post(
        "/auth/login",
        json={"account": "20240002", "password": "captcha-password"},
    )
    assert login_response.status_code == 200
    challenge_data = login_response.json()
    assert challenge_data["status"] == "captcha_required"
    assert challenge_data["captchaToken"] == "captcha-token"
    assert challenge_data["captchaImage"] == "data:image/png;base64,Y2FwdGNoYQ=="

    captcha_response = client.post(
        "/auth/captcha",
        json={"captchaToken": "captcha-token", "code": "1234"},
        headers={"X-Client-Platform": "ios"},
    )

    assert captcha_response.status_code == 200
    captcha_data = captcha_response.json()
    assert captcha_data["studentName"] == "验证码学生"
    assert captcha_data["jwxtCookies"] == "JSESSIONID=captcha-session"
    session = app.state.sessions.get(captcha_data["sessionId"], touch=False)
    assert session is not None
    assert session.student_account == "20240002"
    assert app.state.pending_captcha == {}


def test_login_rejects_missing_password() -> None:
    client = TestClient(create_app())

    missing_password = client.post("/auth/login", json={"account": "20240003"})
    assert missing_password.status_code == 400
    assert missing_password.json()["detail"] == "必须提供 password 或 encryptedPassword"


def test_login_reports_authentication_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    client = TestClient(app)
    rejecting_school = RejectingSchoolConnector()

    def build_client(request: Request) -> RejectingSchoolConnector:
        assert request.url.path == "/auth/login"
        return rejecting_school

    monkeypatch.setattr(auth_routes, "_build_client", build_client)
    rejected = client.post(
        "/auth/login",
        json={"account": "20240003", "password": "wrong-password"},
    )
    assert rejected.status_code == 401
    assert rejected.json()["detail"] == "账号 20240003 登录失败"


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
    state = parse_qs(urlparse(start_response.headers["location"]).query)["state"][0]
    assert app.state.ly_sso_states[state] == return_url

    callback_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-1", "state": state},
        follow_redirects=False,
    )
    assert callback_response.status_code in {302, 307}
    assert callback_response.headers["location"] == return_url
    assert state not in app.state.ly_sso_states

    replay_response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-1", "state": state},
        follow_redirects=False,
    )
    assert replay_response.status_code == 400
    assert replay_response.json()["detail"] == "SSO state 无效"


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
    assert data["jwxtCookies"] == "JSESSIONID=auto-login-session"
    assert decrypt_credentials(
        data["credentialToken"],
        get_settings().credential_encryption_key,
    ) == ("20240004", "auto-login-password")
    session = app.state.sessions.get(data["sessionId"], touch=False)
    assert session is not None
    assert session.student_account == "20240004"


def test_relogin_rejects_invalid_credential_before_cas_request() -> None:
    client = TestClient(create_app())

    response = client.post(
        "/auth/relogin",
        json={"credentialToken": "invalid-token"},
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "凭据已失效，请重新登录"
