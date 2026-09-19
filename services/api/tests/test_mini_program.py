"""微信小程序专用入口的集成测试。

覆盖小程序 MVP 的验收边界：

* 登录响应只含四个安全字段，绝不泄露学校 Cookie、办事大厅 Token 或长期凭据；
* 错误密码、缺失会话、失效会话、退出登录后会话失效；
* 演示账号可依次读取个人信息、课表、成绩、考试、通知、一卡通。

全部用例只走本地演示账号，不发起任何学校系统网络请求。
"""

from fastapi.testclient import TestClient
from types import SimpleNamespace

from app.config import get_settings
from app.database import WechatBinding, get_sync_session_factory
from app.demo_data import DEMO_ACCOUNT, DEMO_STUDENT_ID, DEMO_STUDENT_NAME
from app.main import create_app
from app.routes import mini_program
from app.rate_limit import limiter
from app.school_session_service import SchoolSessionUnavailableError
from app.sessions import AppSession
from app.wechat_identity import WechatIdentity, openid_fingerprint

# 演示账号密码只用于本地测试，真实密码只存在于服务器环境文件。
DEMO_PASSWORD = "Demo-Only-2026!"

SAFE_LOGIN_FIELDS = {"status", "sessionId", "studentName", "studentId"}

# 这些字段一旦出现在小程序响应里就属于凭据泄露。
FORBIDDEN_FIELDS = {
    "credentialToken",
    "jwxtCookies",
    "ehallCookies",
    "ehallAuthToken",
    "authToken",
    "cookies",
    "password",
    "autoLoginToken",
    "rsaPrivateKey",
}

# 教务路由直接挂在根路径下（academic.router 没有 `/academic` 前缀），
# 小程序必须调用这些路径；写成 `/academic/*` 只会得到 404。
PROTECTED_ENDPOINTS = [
    "/me",
    "/schedule",
    "/grades",
    "/exams",
    "/notices",
    "/ecard/summary",
]


def _enable_demo_account(monkeypatch) -> None:
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "true")
    monkeypatch.setenv("DEMO_ACCOUNT", DEMO_ACCOUNT)
    monkeypatch.setenv("DEMO_PASSWORD", DEMO_PASSWORD)
    monkeypatch.setenv("DEMO_STUDENT_ID", DEMO_STUDENT_ID)
    get_settings.cache_clear()


def _login_demo(client: TestClient) -> str:
    response = client.post(
        "/mini/auth/login",
        json={"account": DEMO_ACCOUNT, "password": DEMO_PASSWORD},
    )
    assert response.status_code == 200, response.text
    return response.json()["sessionId"]


def test_mini_program_login_returns_only_short_lived_session(monkeypatch) -> None:
    def fake_auto_login(payload, request) -> dict[str, object]:
        return {
            "status": "ok",
            "sessionId": "mini-session",
            "studentName": "测试同学",
            "studentId": "20260001",
            "credentialToken": "must-not-leak",
            "jwxtCookies": "must-not-leak",
            "ehallCookies": "must-not-leak",
            "ehallAuthToken": "must-not-leak",
        }

    monkeypatch.setattr(mini_program, "auto_login", fake_auto_login)
    client = TestClient(create_app())

    response = client.post(
        "/mini/auth/login",
        json={"account": "20260001", "password": "password"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "sessionId": "mini-session",
        "studentName": "测试同学",
        "studentId": "20260001",
    }


def test_mini_program_login_tolerates_missing_student_name(monkeypatch) -> None:
    """学校没返回姓名时必须照样登录成功。

    `SchoolSdkClient.login_with_cookies` 的签名就是 `str | None`——拿不到姓名是
    上游的正常情况。曾把这种情况当成致命错误抛 RuntimeError，结果变成 500
    「服务器内部错误」，用户完全无法登录，而且 auto_login 里已创建的会话会被泄漏。
    """

    def fake_auto_login(payload, request) -> dict[str, object]:
        return {"status": "ok", "sessionId": "mini-session", "studentName": None, "studentId": "20260001"}

    monkeypatch.setattr(mini_program, "auto_login", fake_auto_login)
    client = TestClient(create_app())

    response = client.post("/mini/auth/login", json={"account": "20260001", "password": "password"})

    assert response.status_code == 200
    payload = response.json()
    assert payload["sessionId"] == "mini-session"
    assert payload["studentName"] == ""
    assert set(payload) == SAFE_LOGIN_FIELDS


def test_mini_program_login_tolerates_non_string_identity_fields(monkeypatch) -> None:
    def fake_auto_login(payload, request) -> dict[str, object]:
        return {"status": "ok", "sessionId": "mini-session", "studentName": 123, "studentId": None}

    monkeypatch.setattr(mini_program, "auto_login", fake_auto_login)
    client = TestClient(create_app())

    response = client.post("/mini/auth/login", json={"account": "20260001", "password": "password"})

    assert response.status_code == 200
    payload = response.json()
    assert payload["studentName"] == ""
    assert payload["studentId"] == ""


def test_mini_program_login_returns_502_not_500_when_session_missing(monkeypatch) -> None:
    """没有会话时客户端什么都做不了，必须失败——但要是 502 + 可读文案，不是 500。"""

    def fake_auto_login(payload, request) -> dict[str, object]:
        return {"status": "ok", "sessionId": None, "studentName": "测试同学", "studentId": "20260001"}

    monkeypatch.setattr(mini_program, "auto_login", fake_auto_login)
    client = TestClient(create_app())

    response = client.post("/mini/auth/login", json={"account": "20260001", "password": "password"})

    assert response.status_code == 502
    assert response.json()["detail"] == "学校系统未建立有效会话，请稍后重试"


def test_mini_program_login_response_contains_no_credential_fields(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/mini/auth/login",
            json={"account": DEMO_ACCOUNT, "password": DEMO_PASSWORD},
        )

    assert response.status_code == 200
    payload = response.json()

    assert set(payload) == SAFE_LOGIN_FIELDS
    assert FORBIDDEN_FIELDS.isdisjoint(payload)

    # 响应体里也不允许以字符串形式夹带 Cookie 或 Token。
    body = response.text
    for marker in ("Cookie", "Token", "token", "password"):
        assert marker not in body, f"登录响应不应包含 {marker}"


def test_mini_program_login_rejects_wrong_password(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/mini/auth/login",
            json={"account": DEMO_ACCOUNT, "password": "wrong-password"},
        )

    assert response.status_code == 401
    assert "sessionId" not in response.json()


def test_mini_program_login_rejects_empty_credentials(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/mini/auth/login",
            json={"account": DEMO_ACCOUNT, "password": ""},
        )

    assert response.status_code in {400, 401, 422}


def test_protected_endpoints_reject_missing_session(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        for endpoint in PROTECTED_ENDPOINTS:
            response = client.get(endpoint)
            assert response.status_code == 401, f"{endpoint} 未登录时应返回 401"


def test_protected_endpoints_reject_unknown_session(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        for endpoint in PROTECTED_ENDPOINTS:
            response = client.get(endpoint, headers={"X-Session-Id": "not-a-real-session"})
            assert response.status_code == 401, f"{endpoint} 失效会话应返回 401"


def test_session_becomes_invalid_after_logout(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        session_id = _login_demo(client)
        headers = {"X-Session-Id": session_id}

        assert client.get("/me", headers=headers).status_code == 200

        logout = client.post("/auth/logout", headers=headers)
        assert logout.status_code == 200

        after = client.get("/me", headers=headers)
        assert after.status_code == 401


def test_demo_account_reads_every_mvp_module(monkeypatch) -> None:
    """演示账号按小程序 MVP 的顺序逐个读取六个模块。"""
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        session_id = _login_demo(client)
        headers = {"X-Session-Id": session_id}

        # 个人信息
        me = client.get("/me", headers=headers)
        assert me.status_code == 200
        assert me.json()["name"] == DEMO_STUDENT_NAME
        assert me.json()["studentId"] == DEMO_STUDENT_ID

        # 课表
        schedule = client.get("/schedule", headers=headers)
        assert schedule.status_code == 200
        courses = schedule.json()
        assert len(courses) == 7
        assert courses[0]["name"] == "软件工程导论"

        # 成绩
        grades = client.get("/grades", headers=headers)
        assert grades.status_code == 200
        assert len(grades.json()) == 5

        # 考试
        exams = client.get("/exams", headers=headers)
        assert exams.status_code == 200
        exam_items = exams.json()
        assert len(exam_items) == 2
        assert exam_items[0]["courseName"] == "数据库原理"

        # 通知
        notices = client.get("/notices", headers=headers)
        assert notices.status_code == 200
        notice_items = notices.json()
        titles = [item["title"] for item in notice_items]
        assert "2026 年秋季学期课程提醒" in titles
        assert all(item["source"] in {"jwxt", "ehall", "admin", "wechat"} for item in notice_items)

        # 一卡通 / 生活缴费
        ecard = client.get("/ecard/summary", headers=headers)
        assert ecard.status_code == 200
        assert ecard.json()["status"] == "ok"
        assert ecard.json()["powerText"] == "68.4 度"


def test_demo_account_module_responses_contain_no_credential_fields(monkeypatch) -> None:
    """六个模块的响应同样不得夹带凭据字段。"""
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        session_id = _login_demo(client)
        headers = {"X-Session-Id": session_id}

        for endpoint in PROTECTED_ENDPOINTS:
            response = client.get(endpoint, headers=headers)
            assert response.status_code == 200, endpoint
            body = response.text
            for marker in ("credentialToken", "ehallAuthToken", "jwxtCookies", "password"):
                assert marker not in body, f"{endpoint} 响应不应包含 {marker}"


class FakeWechatSchoolClient:
    def __init__(self, student_id: str) -> None:
        self._account = student_id

    def get_info(self) -> dict[str, str]:
        return {"studentId": self._account, "name": "绑定用户"}

    def get_jwxt_cookies_string(self) -> str:
        return "encrypted-test-cookie-source"

    def logout(self) -> None:
        return None


def _wechat_session(monkeypatch, application, session_id: str, student_id: str) -> AppSession:
    session = AppSession(
        id=session_id,
        client=FakeWechatSchoolClient(student_id),
        student_name="绑定用户",
        student_account=student_id,
    )
    monkeypatch.setattr(
        application.state.sessions,
        "get",
        lambda requested_id, touch=False, fresh=False: session
        if requested_id == session_id
        else None,
    )
    monkeypatch.setattr(application.state.sessions, "touch", lambda requested_id: None)
    return session


def test_wechat_binding_is_idempotent_and_can_be_unbound(monkeypatch) -> None:
    application = create_app()
    session = _wechat_session(monkeypatch, application, "wechat-session", "20260001")
    identity = WechatIdentity(app_id="wx-test", openid="openid-test")
    monkeypatch.setattr(mini_program, "_exchange_or_raise", lambda code: identity)
    headers = {"X-Session-Id": session.id}

    with TestClient(application) as client:
        first = client.post("/mini/auth/wechat-binding", headers=headers, json={"code": "code-1"})
        repeated = client.post(
            "/mini/auth/wechat-binding", headers=headers, json={"code": "code-2"}
        )
        bound = client.get("/mini/auth/wechat-binding", headers=headers)
        removed = client.delete("/mini/auth/wechat-binding", headers=headers)
        unbound = client.get("/mini/auth/wechat-binding", headers=headers)

    assert first.status_code == 200
    assert repeated.status_code == 200
    assert bound.json() == {"isBound": True}
    assert removed.status_code == 200
    assert unbound.json() == {"isBound": False}

    with get_sync_session_factory()() as db:
        assert db.query(WechatBinding).count() == 0


def test_wechat_binding_rejects_cross_account_and_second_openid_conflicts(monkeypatch) -> None:
    application = create_app()
    session_a = AppSession(
        id="wechat-session-a",
        client=FakeWechatSchoolClient("20260001"),
        student_name="用户甲",
        student_account="20260001",
    )
    session_b = AppSession(
        id="wechat-session-b",
        client=FakeWechatSchoolClient("20260002"),
        student_name="用户乙",
        student_account="20260002",
    )
    sessions = {session_a.id: session_a, session_b.id: session_b}
    monkeypatch.setattr(
        application.state.sessions,
        "get",
        lambda requested_id, touch=False, fresh=False: sessions.get(requested_id),
    )
    monkeypatch.setattr(application.state.sessions, "touch", lambda requested_id: None)
    identity_a = WechatIdentity(app_id="wx-test", openid="openid-a")
    identity_b = WechatIdentity(app_id="wx-test", openid="openid-b")
    current_identity = identity_a
    monkeypatch.setattr(
        mini_program,
        "_exchange_or_raise",
        lambda code: current_identity,
    )

    with TestClient(application) as client:
        headers_a = {"X-Session-Id": session_a.id}
        headers_b = {"X-Session-Id": session_b.id}
        assert client.post(
            "/mini/auth/wechat-binding", headers=headers_a, json={"code": "code-a"}
        ).status_code == 200

        cross_account = client.post(
            "/mini/auth/wechat-binding", headers=headers_b, json={"code": "code-a"}
        )
        current_identity = identity_b
        second_openid = client.post(
            "/mini/auth/wechat-binding", headers=headers_a, json={"code": "code-b"}
        )

    assert cross_account.status_code == 409
    assert cross_account.json()["detail"]["code"] == "wechat_already_bound"
    assert second_openid.status_code == 409
    assert second_openid.json()["detail"]["code"] == "student_already_bound"


def test_wechat_login_requires_binding_and_returns_expired_school_session(monkeypatch) -> None:
    application = create_app()
    identity = WechatIdentity(app_id="wx-test", openid="openid-login")
    monkeypatch.setattr(mini_program, "_exchange_or_raise", lambda code: identity)

    with TestClient(application) as client:
        not_bound = client.post("/mini/auth/wechat-login", json={"code": "code-login"})
        with get_sync_session_factory()() as db:
            db.add(
                WechatBinding(
                    student_id="20260003",
                    openid_fingerprint=openid_fingerprint(identity),
                    encrypted_openid="encrypted-openid",
                    app_id=identity.app_id,
                )
            )
            db.commit()
        monkeypatch.setattr(
            mini_program,
            "load_shared_school_clients",
            lambda student_id: (_ for _ in ()).throw(
                SchoolSessionUnavailableError("expired")
            ),
        )
        expired = client.post("/mini/auth/wechat-login", json={"code": "code-login"})

    assert not_bound.status_code == 409
    assert not_bound.json()["detail"]["code"] == "wechat_not_bound"
    assert expired.status_code == 428
    assert expired.json()["detail"]["code"] == "school_session_expired"
    assert "openid-login" not in expired.text
    assert "code-login" not in expired.text


def test_wechat_login_creates_a_new_short_session(monkeypatch) -> None:
    application = create_app()
    identity = WechatIdentity(app_id="wx-test", openid="openid-login-ok")
    monkeypatch.setattr(mini_program, "_exchange_or_raise", lambda code: identity)
    client = FakeWechatSchoolClient("20260004")
    shared = SimpleNamespace(student_name="登录用户", version=7)
    monkeypatch.setattr(
        mini_program,
        "load_shared_school_clients",
        lambda student_id: (client, None, shared),
    )

    with TestClient(application) as test_client:
        with get_sync_session_factory()() as db:
            db.add(
                WechatBinding(
                    student_id="20260004",
                    openid_fingerprint=openid_fingerprint(identity),
                    encrypted_openid="encrypted-openid",
                    app_id=identity.app_id,
                )
            )
            db.commit()
        response = test_client.post("/mini/auth/wechat-login", json={"code": "code-login-ok"})

    assert response.status_code == 200
    assert set(response.json()) == SAFE_LOGIN_FIELDS
    assert response.json()["studentId"] == "20260004"
    assert response.json()["studentName"] == "登录用户"
    assert "openid-login-ok" not in response.text
    assert "code-login-ok" not in response.text


def test_wechat_login_reports_missing_configuration(monkeypatch) -> None:
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "")
    get_settings.cache_clear()
    application = create_app()
    with TestClient(application) as client:
        response = client.post("/mini/auth/wechat-login", json={"code": "code-without-config"})
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "wechat_not_configured"


def test_wechat_login_is_rate_limited(monkeypatch) -> None:
    limiter.reset()
    application = create_app()
    identity = WechatIdentity(app_id="wx-test", openid="openid-rate")
    monkeypatch.setattr(mini_program, "_exchange_or_raise", lambda code: identity)
    with TestClient(application) as client:
        responses = [
            client.post("/mini/auth/wechat-login", json={"code": f"code-{index}"})
            for index in range(11)
        ]
    assert responses[-1].status_code == 429
