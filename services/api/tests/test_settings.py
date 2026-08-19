from fastapi.testclient import TestClient
from sqlalchemy import inspect

from app import database
from app.config import get_settings
from app.database import UserSettings, get_sync_session_factory
from app.main import app
from app.routes import settings as settings_route
from app.sessions import AppSession


class FakeSchoolClient:
    def __init__(self, student_id="20240001"):
        self._student_id = student_id

    def get_info(self):
        return {"studentId": self._student_id, "name": "测试用户"}

    def logout(self):
        pass


def _authed_session(monkeypatch, session_id="test-session", student_id="20240001"):
    session = AppSession(
        id=session_id,
        client=FakeSchoolClient(student_id),
        student_name="测试用户",
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return session


def test_get_schedule_settings_requires_session():
    with TestClient(app) as client:
        response = client.get("/settings/schedule")
    assert response.status_code == 401


def test_get_schedule_settings_returns_defaults_when_not_saved(monkeypatch):
    session = _authed_session(monkeypatch)
    with TestClient(app) as client:
        response = client.get("/settings/schedule", headers={"X-Session-Id": session.id})
    assert response.status_code == 200
    assert response.json() == {
        "firstWeeks": {},
        "autoWeek": True,
        "onboardingCompleted": False,
    }


def test_put_schedule_settings_creates_row(monkeypatch):
    session = _authed_session(monkeypatch)
    with TestClient(app) as client:
        response = client.put(
            "/settings/schedule",
            headers={"X-Session-Id": session.id},
            json={
                "firstWeeks": {"2026-1": "2026-09-01"},
                "onboardingCompleted": True,
            },
        )
    assert response.status_code == 200
    body = response.json()
    assert body["firstWeeks"] == {"2026-1": "2026-09-01"}
    assert body["autoWeek"] is True
    assert body["onboardingCompleted"] is True

    # 数据已按学号落库
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(UserSettings).filter(UserSettings.student_id == "20240001").first()
        assert row is not None
        assert row.onboarding_completed is True


def test_put_schedule_settings_merges_first_weeks(monkeypatch):
    session = _authed_session(monkeypatch)
    with TestClient(app) as client:
        headers = {"X-Session-Id": session.id}
        client.put(
            "/settings/schedule",
            headers=headers,
            json={"firstWeeks": {"2026-1": "2026-09-01"}},
        )
        response = client.put(
            "/settings/schedule",
            headers=headers,
            json={"firstWeeks": {"2026-2": "2027-03-01"}},
        )
    assert response.status_code == 200
    assert response.json()["firstWeeks"] == {
        "2026-1": "2026-09-01",
        "2026-2": "2027-03-01",
    }


def test_put_schedule_settings_partial_update_keeps_other_fields(monkeypatch):
    session = _authed_session(monkeypatch)
    with TestClient(app) as client:
        headers = {"X-Session-Id": session.id}
        client.put(
            "/settings/schedule",
            headers=headers,
            json={
                "firstWeeks": {"2026-1": "2026-09-01"},
                "autoWeek": True,
                "onboardingCompleted": True,
            },
        )
        response = client.put(
            "/settings/schedule",
            headers=headers,
            json={"autoWeek": False},
        )
    assert response.status_code == 200
    body = response.json()
    assert body["autoWeek"] is False
    assert body["onboardingCompleted"] is True
    assert body["firstWeeks"] == {"2026-1": "2026-09-01"}


def test_schedule_settings_are_scoped_per_student(monkeypatch):
    session_a = AppSession(
        id="session-a",
        client=FakeSchoolClient("20240001"),
        student_name="用户甲",
    )
    session_b = AppSession(
        id="session-b",
        client=FakeSchoolClient("20240002"),
        student_name="用户乙",
    )
    by_id = {session_a.id: session_a, session_b.id: session_b}
    monkeypatch.setattr(
        app.state.sessions, "get", lambda session_id, touch=True: by_id[session_id]
    )
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    with TestClient(app) as client:
        client.put(
            "/settings/schedule",
            headers={"X-Session-Id": session_a.id},
            json={"firstWeeks": {"2026-1": "2026-09-01"}},
        )
        response_b = client.get("/settings/schedule", headers={"X-Session-Id": session_b.id})
    assert response_b.status_code == 200
    assert response_b.json()["firstWeeks"] == {}
    assert response_b.json()["onboardingCompleted"] is False


def test_put_schedule_settings_rejects_unknown_fields(monkeypatch):
    session = _authed_session(monkeypatch)
    with TestClient(app) as client:
        response = client.put(
            "/settings/schedule",
            headers={"X-Session-Id": session.id},
            json={"foo": "bar"},
        )
    assert response.status_code == 422


def test_ensure_table_creates_user_settings_when_init_db_skipped(monkeypatch):
    """生产（Vercel）init_db 跳过全部建表，懒建表 helper 必须能补建表。

    回归测试：新表首次访问若不补建，Vercel 上会一直 500。
    """
    monkeypatch.setenv("VERCEL", "1")
    monkeypatch.setenv("DEBUG", "false")
    # 生产配置校验要求 RSA_PRIVATE_KEY 非空（本测试不涉及 RSA，占位即可）
    monkeypatch.setenv("RSA_PRIVATE_KEY", "test-rsa-key")
    get_settings.cache_clear()
    database.reset_engine()
    settings_route._table_ready = False

    engine = database.get_sync_engine()
    assert not inspect(engine).has_table("user_settings")

    settings_route._ensure_table()

    assert inspect(engine).has_table("user_settings")
    assert settings_route._table_ready is True
