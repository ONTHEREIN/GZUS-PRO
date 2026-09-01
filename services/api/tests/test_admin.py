from fastapi.testclient import TestClient
from sqlalchemy import inspect

from app import database
from app.config import get_settings
from app.database import (
    AdminAuditLog,
    AdminUser,
    AppSessionModel,
    CredentialRevocation,
    get_sync_session_factory,
)
from app.main import app
from app.routes import admin as admin_route
from app.sessions import AppSession


class FakeSchoolClient:
    def __init__(self, student_id="20240001"):
        self._student_id = student_id

    def get_info(self):
        return {"studentId": self._student_id, "name": "测试用户"}

    def logout(self):
        pass


def _authed_session(
    monkeypatch,
    session_id="test-session",
    student_id="20240001",
    is_admin=True,
):
    session = AppSession(
        id=session_id,
        client=FakeSchoolClient(student_id),
        student_name="测试用户",
        is_admin=is_admin,
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return session


def _add_admin(student_id: str, role: str = "admin") -> None:
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(AdminUser(student_id=student_id, role=role))
        db.commit()


def _add_session_row(
    session_id: str,
    student_id: str,
    is_admin: bool = False,
    credential_fingerprint: str | None = None,
) -> None:
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            AppSessionModel(
                id=session_id,
                student_name="目标用户",
                student_account=student_id,
                is_admin=is_admin,
                credential_fingerprint=credential_fingerprint,
            )
        )
        db.commit()


def test_admin_me_requires_session():
    with TestClient(app) as client:
        response = client.get("/admin/me")
    assert response.status_code == 401


def test_admin_me_forbidden_for_non_admin(monkeypatch):
    _authed_session(monkeypatch, is_admin=False)
    with TestClient(app) as client:
        response = client.get("/admin/me", headers={"X-Session-Id": "test-session"})
    assert response.status_code == 403


def test_admin_me_ok_for_admin(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    with TestClient(app) as client:
        response = client.get("/admin/me", headers={"X-Session-Id": "test-session"})
    assert response.status_code == 200
    body = response.json()
    assert body["is_admin"] is True
    assert body["role"] == "owner"
    assert body["student_id"] == "20240001"


def test_admin_overview_ok(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001")
    with TestClient(app) as client:
        response = client.get("/admin/overview", headers={"X-Session-Id": "test-session"})
    assert response.status_code == 200
    body = response.json()
    assert "totalSessions" in body
    assert "activeSessions" in body
    assert body["adminUsers"] == 1


def test_admin_sessions_lists(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001")
    _add_session_row("target-session", "20240002", credential_fingerprint="a" * 64)
    with TestClient(app) as client:
        response = client.get("/admin/sessions", headers={"X-Session-Id": "test-session"})
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 1
    assert body["items"][0]["studentAccount"] == "20240002"


def test_admin_revoke_session(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    _add_session_row("target-session", "20240002", credential_fingerprint="a" * 64)
    with TestClient(app) as client:
        response = client.post(
            "/admin/sessions/target-session/revoke",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 200
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == "target-session").first()
        assert row.revoked_at is not None
        assert row.revoked_reason == "admin_kick"
        revoked_credential = db.get(CredentialRevocation, "a" * 64)
        assert revoked_credential is not None
        assert revoked_credential.reason == "admin_kick"
        # 审计日志已落库
        log = db.query(AdminAuditLog).filter(AdminAuditLog.action == "revoke_session").first()
        assert log is not None
        assert log.operator_id == "20240001"
        assert log.target_id == "target-session"


def test_admin_revoke_own_session_forbidden(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001")
    _add_session_row("test-session", "20240001")
    with TestClient(app) as client:
        response = client.post(
            "/admin/sessions/test-session/revoke",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 400


def test_admin_cannot_revoke_owner(monkeypatch):
    """admin 角色不能踢 owner 的会话（owner 可以）。"""
    _authed_session(monkeypatch)
    _add_admin("20240001", role="admin")
    _add_admin("20240009", role="owner")
    _add_session_row("owner-session", "20240009", is_admin=True)
    with TestClient(app) as client:
        response = client.post(
            "/admin/sessions/owner-session/revoke",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 403


def test_admin_add_user_owner_only(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="admin")
    with TestClient(app) as client:
        response = client.post(
            "/admin/users",
            headers={"X-Session-Id": "test-session"},
            json={"studentId": "20240003", "role": "admin"},
        )
    assert response.status_code == 403  # admin 无权增删管理员


def test_admin_add_user_ok(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    with TestClient(app) as client:
        response = client.post(
            "/admin/users",
            headers={"X-Session-Id": "test-session"},
            json={"studentId": "20240003", "role": "admin"},
        )
    assert response.status_code == 201
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminUser).filter(AdminUser.student_id == "20240003").first()
        assert row is not None
        assert row.role == "admin"
        log = db.query(AdminAuditLog).filter(AdminAuditLog.action == "add_admin").first()
        assert log is not None
        assert log.target_id == "20240003"


def test_admin_add_user_duplicate_conflict(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    _add_admin("20240003")
    with TestClient(app) as client:
        response = client.post(
            "/admin/users",
            headers={"X-Session-Id": "test-session"},
            json={"studentId": "20240003", "role": "admin"},
        )
    assert response.status_code == 409


def test_admin_remove_last_owner_forbidden(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    with TestClient(app) as client:
        response = client.delete(
            "/admin/users/20240001",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 400  # 不能删自己的身份


def test_admin_remove_user_ok(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    _add_admin("20240003")
    with TestClient(app) as client:
        response = client.delete(
            "/admin/users/20240003",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 200
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminUser).filter(AdminUser.student_id == "20240003").first()
        assert row is None
        log = db.query(AdminAuditLog).filter(AdminAuditLog.action == "remove_admin").first()
        assert log is not None


def test_seed_owner_from_env(monkeypatch):
    """ADMIN_SEED_OWNER 配置的学号幂等写入 admin_users 作为 owner。"""
    monkeypatch.setenv("ADMIN_SEED_OWNER", "20240099,20240098")
    get_settings.cache_clear()
    database.reset_engine()
    admin_route._tables_ready = False

    admin_route.ensure_admin_tables()

    factory = get_sync_session_factory()
    with factory() as db:
        row_a = db.query(AdminUser).filter(AdminUser.student_id == "20240099").first()
        row_b = db.query(AdminUser).filter(AdminUser.student_id == "20240098").first()
        assert row_a is not None and row_a.role == "owner"
        assert row_b is not None and row_b.role == "owner"

    # 再次调用保持幂等（不重复插入/不报错）
    admin_route.ensure_admin_tables()
    with factory() as db:
        count = db.query(AdminUser).filter(AdminUser.student_id == "20240099").count()
        assert count == 1


def test_ensure_table_keeps_admin_tables_available(monkeypatch):
    """常驻服务的管理员建表 helper 保持幂等。"""
    database.reset_engine()
    admin_route._tables_ready = False

    admin_route.ensure_admin_tables()

    assert inspect(database.get_sync_engine()).has_table("admin_users")
    assert inspect(database.get_sync_engine()).has_table("admin_audit_log")
    assert admin_route._tables_ready is True


def test_admin_cache_clear_writes_audit(monkeypatch):
    _authed_session(monkeypatch)
    _add_admin("20240001", role="owner")
    with TestClient(app) as client:
        response = client.post(
            "/admin/cache/clear",
            headers={"X-Session-Id": "test-session"},
        )
    assert response.status_code == 200
    assert response.json()["ok"] is True
    factory = get_sync_session_factory()
    with factory() as db:
        log = db.query(AdminAuditLog).filter(AdminAuditLog.action == "clear_cache").first()
        assert log is not None
        assert log.operator_id == "20240001"
