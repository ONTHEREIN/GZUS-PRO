from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import create_app


DEMO_ACCOUNT = "demo_screenshot_2026"
DEMO_PASSWORD = "Demo-Only-2026!"


def _enable_demo_account(monkeypatch) -> None:
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "true")
    monkeypatch.setenv("DEMO_ACCOUNT", DEMO_ACCOUNT)
    monkeypatch.setenv("DEMO_PASSWORD", DEMO_PASSWORD)
    monkeypatch.setenv("DEMO_STUDENT_ID", "DEMO-2026-001")
    get_settings.cache_clear()


def test_demo_account_login_and_read_only_data(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/auth/auto-login",
            json={"account": DEMO_ACCOUNT, "password": DEMO_PASSWORD},
        )

        assert response.status_code == 200
        login = response.json()
        assert login["studentId"] == "DEMO-2026-001"
        assert login["studentName"] == "演示同学"
        assert login["credentialToken"] is None
        headers = {"X-Session-Id": login["sessionId"]}

        dashboard = client.get("/dashboard?includePublic=false", headers=headers)
        assert dashboard.status_code == 200
        modules = dashboard.json()["modules"]
        assert modules["me"]["data"]["name"] == "演示同学"
        assert len(modules["schedule"]["data"]) == 7
        assert len(modules["grades"]["data"]) == 5
        assert len(modules["exams"]["data"]) == 2
        assert modules["ecard"]["data"]["powerText"] == "68.4 度"
        assert modules["apps"]["data"][0]["title"] == "校园卡服务"

        assert client.get("/ecard/consumption", headers=headers).json()["status"] == "ok"
        assert client.get("/ehall/affairs", headers=headers).json()[0]["title"] == "学生请假"

        write_response = client.put(
            "/settings/schedule",
            headers=headers,
            json={"autoWeek": False},
        )
        assert write_response.status_code == 403
        assert write_response.json()["detail"] == "演示账号仅支持查看"


def test_demo_account_rejects_wrong_password(monkeypatch) -> None:
    _enable_demo_account(monkeypatch)
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/auth/auto-login",
            json={"account": DEMO_ACCOUNT, "password": "wrong-password"},
        )

    assert response.status_code == 401


def test_demo_account_is_rejected_when_disabled(monkeypatch) -> None:
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "false")
    monkeypatch.setenv("DEMO_PASSWORD", DEMO_PASSWORD)
    get_settings.cache_clear()
    app = create_app()

    with TestClient(app) as client:
        response = client.post(
            "/auth/auto-login",
            json={"account": DEMO_ACCOUNT, "password": DEMO_PASSWORD},
        )

    assert response.status_code == 401
