from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.database import AppSessionModel, get_sync_session_factory
from app.main import create_app
from app.routes.deps import SESSION_IDLE_STALE_THRESHOLD, require_session
from app.sessions import SessionStore, SessionStoreUnavailableError


class _Client:
    def __init__(self, account: str | None = None) -> None:
        self._account = account

    def get_jwxt_cookies_string(self) -> str:
        return "JSESSIONID=test"

    def logout(self) -> None:
        pass


def _request_for(store: SessionStore):
    return SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(sessions=store)),
        url=SimpleNamespace(path="/schedule"),
        headers={},
    )


def _set_last_active(session_id: str, value: datetime) -> None:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
        assert row is not None
        row.last_active_at = value
        db.commit()


def _get_row(session_id: str) -> AppSessionModel:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
        assert row is not None
        return row


def test_require_session_rejects_idle_session_before_touching_it():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    stale_at = (
        datetime.now(timezone.utc).replace(tzinfo=None)
        - SESSION_IDLE_STALE_THRESHOLD
        - timedelta(seconds=1)
    )
    _set_last_active(session.id, stale_at)
    session.last_active_at = stale_at
    store._session_checked_at.pop(session.id, None)

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=session.id)

    assert exc.value.status_code == 401
    assert _get_row(session.id).last_active_at.replace(microsecond=0) == stale_at.replace(
        microsecond=0
    )


def test_require_session_uses_memory_cache_without_immediate_db_touch():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    old_active_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=10)
    _set_last_active(session.id, old_active_at)

    result = require_session(_request_for(store), x_session_id=session.id)

    assert result.id == session.id
    assert _get_row(session.id).last_active_at.replace(microsecond=0) == old_active_at.replace(
        microsecond=0
    )


def test_require_session_touches_db_after_throttle_window():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    old_active_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(minutes=2)
    _set_last_active(session.id, old_active_at)
    session.last_active_at = old_active_at
    store._session_checked_at.pop(session.id, None)
    store._last_touch_at[session.id] = old_active_at

    result = require_session(_request_for(store), x_session_id=session.id)

    assert result.id == session.id
    assert _get_row(session.id).last_active_at > old_active_at


def test_create_revokes_existing_session_for_same_account():
    store = SessionStore(ttl_seconds=7200)
    first = store.create(_Client("20240001"), "测试学生", student_account="20240001")
    second = store.create(_Client("20240001"), "测试学生", student_account="20240001")

    first_row = _get_row(first.id)
    second_row = _get_row(second.id)
    assert first_row.revoked_at is not None
    assert first_row.revoked_reason == "single_device_login"
    assert second_row.revoked_at is None


def test_create_clears_legacy_persisted_login_credentials():
    first_store = SessionStore(ttl_seconds=7200)
    first = first_store.create(_Client("20240001"), student_account="20240001")
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == first.id).first()
        assert row is not None
        row.encrypted_credentials = "legacy-encrypted-password"
        db.commit()

    second_store = SessionStore(ttl_seconds=7200)
    second_store.create(_Client("20240002"), student_account="20240002")

    assert _get_row(first.id).encrypted_credentials is None


def test_require_session_rejects_revoked_session_without_relogin_loop():
    store = SessionStore(ttl_seconds=7200)
    first = store.create(_Client("20240001"), "测试学生", student_account="20240001")
    store.create(_Client("20240001"), "测试学生", student_account="20240001")

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=first.id)

    assert exc.value.status_code == 401
    assert exc.value.detail == "账号已在其他设备登录，请重新登录"


def test_get_raises_when_session_database_is_unavailable(monkeypatch):
    attempts = 0

    def unavailable_factory():
        nonlocal attempts
        attempts += 1
        raise ConnectionError("database offline")

    monkeypatch.setattr("app.sessions.time.sleep", lambda _seconds: None)
    store = SessionStore(ttl_seconds=7200, db_factory=unavailable_factory)

    with pytest.raises(SessionStoreUnavailableError, match="operation=get") as exc:
        store.get("session-id", touch=False)

    assert attempts == 3
    assert isinstance(exc.value.__cause__, ConnectionError)


def test_session_database_failure_returns_503(monkeypatch):
    def unavailable_factory():
        raise ConnectionError("database offline")

    monkeypatch.setattr("app.sessions.time.sleep", lambda _seconds: None)
    app = create_app()
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=unavailable_factory)
    client = TestClient(app)

    response = client.get("/me", headers={"X-Session-Id": "session-id"})

    assert response.status_code == 503
    assert response.json() == {"detail": "会话服务暂时不可用，请稍后重试"}
