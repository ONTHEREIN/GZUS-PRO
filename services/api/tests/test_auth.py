from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs, urlparse

from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import create_app
from app.routes import auth


class FakeSchoolClient:
    logged_out = False

    def __init__(self, base_url, timeout_seconds):
        self.base_url = base_url
        self.timeout_seconds = timeout_seconds

    def login(self, account, password):
        assert account == "20240001"
        assert password == "secret"
        return "测试学生"

    def logout(self):
        self.logged_out = True


def test_login_returns_application_session(monkeypatch):
    monkeypatch.setattr(auth, "SchoolSdkClient", FakeSchoolClient)
    client = TestClient(create_app())

    response = client.post("/auth/login", json={"account": "20240001", "password": "secret"})

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["studentName"] == "测试学生"
    assert body["sessionId"]


def test_logout_deletes_session(monkeypatch):
    monkeypatch.setattr(auth, "SchoolSdkClient", FakeSchoolClient)
    app = create_app()
    client = TestClient(app)
    login = client.post("/auth/login", json={"account": "20240001", "password": "secret"}).json()

    response = client.post("/auth/logout", headers={"X-Session-Id": login["sessionId"]})

    assert response.status_code == 200
    assert app.state.sessions.get(login["sessionId"]) is None


def test_ly_sso_start_redirects_to_cas_login():
    settings = get_settings()
    original_public_api_base_url = settings.public_api_base_url
    settings.public_api_base_url = "https://gzus-pro.example.edu.cn"
    client = TestClient(create_app())

    try:
        response = client.get("/auth/ly/start", follow_redirects=False)
    finally:
        settings.public_api_base_url = original_public_api_base_url

    assert response.status_code == 303
    location = response.headers["location"]
    assert location.startswith("https://cas.gzus.edu.cn/lyuapServer/login?")
    service = parse_qs(urlparse(location).query)["service"][0]
    assert service.startswith("https://gzus-pro.example.edu.cn/auth/ly/callback?")


def test_ly_sso_start_rejects_unregistered_local_callback():
    client = TestClient(create_app())

    response = client.get("/auth/ly/start", follow_redirects=False)

    assert response.status_code == 303
    location = response.headers["location"]
    assert location.startswith("http://localhost:8080?")
    assert "ssoError=" in location


def test_ly_sso_callback_rejects_expired_state():
    client = TestClient(create_app())

    response = client.get(
        "/auth/ly/callback?state=missing&ticket=ST-1",
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert "ssoError=" in response.headers["location"]


class FakeSsoSchoolClient:
    def __init__(self, base_url, timeout_seconds):
        self.base_url = base_url
        self.timeout_seconds = timeout_seconds
        self.cookies = None
        self.account = None
        self.logged_out = False

    def login_with_cookies(self, cookies, account):
        self.cookies = cookies
        self.account = account
        return "联奕学生"

    def logout(self):
        self.logged_out = True


class BrokenSsoSchoolClient(FakeSsoSchoolClient):
    def login_with_cookies(self, cookies, account):
        raise auth.AuthenticationError("教务系统 cookie 登录验证失败")


class FakeHttpResponse:
    def __init__(self, text="", cookies=None):
        self.text = text
        self.cookies = cookies or {}

    def raise_for_status(self):
        return None


class FakeHttpClient:
    def __init__(self, *args, **kwargs):
        self.cookies = {}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def get(self, url, params=None):
        if url.endswith("/serviceValidate"):
            return FakeHttpResponse(
                """
                <cas:serviceResponse xmlns:cas="http://www.yale.edu/tp/cas">
                  <cas:authenticationSuccess>
                    <cas:user>20240001</cas:user>
                    <cas:proxyGrantingTicket>PGTIOU-1</cas:proxyGrantingTicket>
                  </cas:authenticationSuccess>
                </cas:serviceResponse>
                """
            )
        if url.endswith("/proxy"):
            assert params["pgt"] == "PGT-1"
            return FakeHttpResponse(
                """
                <cas:serviceResponse xmlns:cas="http://www.yale.edu/tp/cas">
                  <cas:proxySuccess>
                    <cas:proxyTicket>PT-1</cas:proxyTicket>
                  </cas:proxySuccess>
                </cas:serviceResponse>
                """
            )
        assert url == "https://jwxt.seig.edu.cn/sso/lyiotlogin"
        assert params["ticket"] == "PT-1"
        self.cookies = {"JSESSIONID": "abc123"}
        return FakeHttpResponse()


def test_ly_sso_callback_and_complete_create_application_session(monkeypatch):
    monkeypatch.setattr(auth.httpx, "Client", FakeHttpClient)
    monkeypatch.setattr(auth, "SchoolSdkClient", FakeSsoSchoolClient)
    app = create_app()
    app.state.ly_sso_states["STATE-1"] = auth.LySsoState(
        return_url="http://localhost:8080",
        expires_at=datetime.now(UTC) + timedelta(minutes=5),
    )
    app.state.ly_sso_proxy_granting_tickets["PGTIOU-1"] = auth.LyProxyGrantingTicket(
        pgt_id="PGT-1",
        expires_at=datetime.now(UTC) + timedelta(minutes=5),
    )
    client = TestClient(app)

    callback = client.get(
        "/auth/ly/callback?state=STATE-1&ticket=ST-1",
        follow_redirects=False,
    )

    assert callback.status_code == 303
    sso_code = parse_qs(urlparse(callback.headers["location"]).query)["ssoCode"][0]

    complete = client.post("/auth/ly/complete", json={"ssoCode": sso_code})

    assert complete.status_code == 200
    body = complete.json()
    assert body["status"] == "ok"
    assert body["studentName"] == "联奕学生"
    assert body["sessionId"]

    second_complete = client.post("/auth/ly/complete", json={"ssoCode": sso_code})
    assert second_complete.status_code == 400


class NoCookieHttpClient(FakeHttpClient):
    def get(self, url, params=None):
        if url == "https://jwxt.seig.edu.cn/sso/lyiotlogin":
            return FakeHttpResponse()
        return super().get(url, params)


def test_ly_sso_callback_reports_missing_jwxt_cookie(monkeypatch):
    monkeypatch.setattr(auth.httpx, "Client", NoCookieHttpClient)
    app = create_app()
    app.state.ly_sso_states["STATE-1"] = auth.LySsoState(
        return_url="http://localhost:8080",
        expires_at=datetime.now(UTC) + timedelta(minutes=5),
    )
    app.state.ly_sso_proxy_granting_tickets["PGTIOU-1"] = auth.LyProxyGrantingTicket(
        pgt_id="PGT-1",
        expires_at=datetime.now(UTC) + timedelta(minutes=5),
    )
    client = TestClient(app)

    response = client.get(
        "/auth/ly/callback?state=STATE-1&ticket=ST-1",
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert "ssoError=" in response.headers["location"]


def test_mobile_cookie_login_creates_application_session(monkeypatch):
    monkeypatch.setattr(auth, "SchoolSdkClient", FakeSsoSchoolClient)
    client = TestClient(create_app())

    response = client.post(
        "/auth/mobile-cookie-login",
        json={"account": "20240001", "cookies": "JSESSIONID=abc123"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["studentName"] == "联奕学生"
    assert body["sessionId"]


def test_mobile_cookie_login_rejects_blank_cookie(monkeypatch):
    monkeypatch.setattr(auth, "SchoolSdkClient", FakeSsoSchoolClient)
    client = TestClient(create_app())

    response = client.post(
        "/auth/mobile-cookie-login",
        json={"account": "20240001", "cookies": "   "},
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "未获取到教务系统 cookie"


def test_mobile_cookie_login_reports_sdk_failure(monkeypatch):
    monkeypatch.setattr(auth, "SchoolSdkClient", BrokenSsoSchoolClient)
    client = TestClient(create_app())

    response = client.post(
        "/auth/mobile-cookie-login",
        json={"account": "20240001", "cookies": "JSESSIONID=abc123"},
    )

    assert response.status_code == 401
