from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.database import AppSessionModel, get_sync_session_factory
from app.routes.deps import SESSION_IDLE_STALE_THRESHOLD, require_session
from app.sessions import SessionStore


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

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=session.id)

    assert exc.value.status_code == 401
    assert _get_row(session.id).last_active_at.replace(microsecond=0) == stale_at.replace(
        microsecond=0
    )


def test_require_session_touches_fresh_session_after_validation():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    old_active_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=10)
    _set_last_active(session.id, old_active_at)

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


def test_require_session_rejects_revoked_session_without_relogin_loop():
    store = SessionStore(ttl_seconds=7200)
    first = store.create(_Client("20240001"), "测试学生", student_account="20240001")
    store.create(_Client("20240001"), "测试学生", student_account="20240001")

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=first.id)

    assert exc.value.status_code == 401
    assert exc.value.detail == "账号已在其他设备登录，请重新登录"
