from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.database import (
    AppSessionModel,
    IosLiveActivityToken,
    IosPushToken,
    SchoolAccountSession,
    WebPushSubscription,
    get_sync_session_factory,
)
from app.main import create_app
from app.routes.deps import require_session
from app.sessions import CredentialRevokedError, SessionStore, SessionStoreUnavailableError


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


def test_require_session_accepts_idle_school_session_before_application_ttl():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    stale_at = (
        datetime.now(timezone.utc).replace(tzinfo=None)
        - timedelta(minutes=26)
    )
    _set_last_active(session.id, stale_at)
    session.last_active_at = stale_at
    store._session_checked_at.pop(session.id, None)

    assert require_session(_request_for(store), x_session_id=session.id).id == session.id


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


def test_create_allows_multiple_sessions_for_same_account():
    store = SessionStore(ttl_seconds=7200)
    first = store.create(_Client("20240001"), "测试学生", student_account="20240001")
    second = store.create(_Client("20240001"), "测试学生", student_account="20240001")

    first_row = _get_row(first.id)
    second_row = _get_row(second.id)
    assert first_row.revoked_at is None
    assert second_row.revoked_at is None


def test_create_populates_legacy_push_platform_column():
    store = SessionStore(ttl_seconds=7200)

    session = store.create(_Client("20240001"), student_account="20240001")

    assert _get_row(session.id).push_platform == "legacy"


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


def test_require_session_rejects_admin_revoked_session():
    store = SessionStore(ttl_seconds=7200)
    first = store.create(_Client("20240001"), "测试学生", student_account="20240001")
    assert store.revoke(first.id, reason="admin_kick")

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=first.id)

    assert exc.value.status_code == 401
    assert exc.value.detail == "当前设备已被管理员下线，请重新验证登录"


def test_put_rechecks_session_revoked_by_another_process():
    local_store = SessionStore(ttl_seconds=7200)
    session = local_store.create(_Client())
    assert local_store.get(session.id) is not None
    remote_store = SessionStore(ttl_seconds=7200)
    assert remote_store.revoke(session.id, reason="admin_kick")

    request = _request_for(local_store)
    request.method = "PUT"
    with pytest.raises(HTTPException) as exc:
        require_session(request, x_session_id=session.id)

    assert exc.value.status_code == 401


def test_admin_credential_revocation_is_persistent():
    store = SessionStore(ttl_seconds=7200)
    fingerprint = "a" * 64

    assert store.is_credential_revoked(fingerprint) is False
    store.revoke_credential(fingerprint, reason="admin_kick")

    assert store.is_credential_revoked(fingerprint) is True

    with pytest.raises(CredentialRevokedError):
        store.create(_Client("20240001"), student_account="20240001", credential_fingerprint=fingerprint)
    with get_sync_session_factory()() as db:
        assert db.query(AppSessionModel).count() == 0


def test_expired_session_push_targets_follow_credential_revocation():
    store = SessionStore(ttl_seconds=7200)
    fingerprint = "a" * 64
    persistent = store.create(_Client(), credential_fingerprint=fingerprint)
    temporary = store.create(_Client())
    with get_sync_session_factory()() as db:
        db.add(WebPushSubscription(
            student_id="20240001", session_id=persistent.id,
            credential_fingerprint=fingerprint,
            endpoint="https://fcm.googleapis.com/persistent", p256dh="key", auth="auth",
        ))
        db.add(IosPushToken(
            student_id="20240001", session_id=persistent.id,
            credential_fingerprint=fingerprint,
            device_token="a" * 64, environment="production",
        ))
        db.add(IosLiveActivityToken(
            student_id="20240001", session_id=persistent.id,
            credential_fingerprint=fingerprint,
            token_type="start", token="b" * 64, environment="production",
        ))
        db.add(WebPushSubscription(
            student_id="20240001", session_id=temporary.id,
            endpoint="https://fcm.googleapis.com/temporary", p256dh="key", auth="auth",
        ))
        db.commit()
    expired_at = datetime.now(timezone.utc) - timedelta(hours=3)
    _set_last_active(persistent.id, expired_at)
    _set_last_active(temporary.id, expired_at)

    store._purge_expired()

    with get_sync_session_factory()() as db:
        assert db.query(AppSessionModel).count() == 0
        assert [row.session_id for row in db.query(WebPushSubscription).all()] == [persistent.id]
        assert db.query(IosPushToken).count() == 1
        assert db.query(IosLiveActivityToken).count() == 1

    store.revoke_credential(fingerprint, reason="admin_kick")

    with get_sync_session_factory()() as db:
        for model in (WebPushSubscription, IosPushToken, IosLiveActivityToken):
            assert db.query(model).count() == 0


def test_get_expired_session_cleans_unowned_push_targets():
    store = SessionStore(ttl_seconds=7200)
    temporary = store.create(_Client("20240001"), student_account="20240001")
    fingerprint = "a" * 64
    persistent = store.create(
        _Client("20240001"), student_account="20240001",
        credential_fingerprint=fingerprint,
    )
    with get_sync_session_factory()() as db:
        db.add(SchoolAccountSession(student_id="20240001"))
        db.add(WebPushSubscription(
            student_id="20240001", session_id=temporary.id,
            endpoint="https://fcm.googleapis.com/temporary", p256dh="key", auth="auth",
        ))
        db.add(IosPushToken(
            student_id="20240001", session_id=temporary.id,
            device_token="a" * 64, environment="production",
        ))
        db.add(IosLiveActivityToken(
            student_id="20240001", session_id=temporary.id,
            token_type="start", token="b" * 64, environment="production",
        ))
        db.add(WebPushSubscription(
            student_id="20240001", session_id=persistent.id,
            credential_fingerprint=fingerprint,
            endpoint="https://fcm.googleapis.com/persistent", p256dh="key", auth="auth",
        ))
        db.commit()
    expired_at = datetime.now(timezone.utc) - timedelta(hours=3)
    _set_last_active(temporary.id, expired_at)
    _set_last_active(persistent.id, expired_at)

    assert store.get(temporary.id, fresh=True) is None
    assert store.get(persistent.id, fresh=True) is None

    with get_sync_session_factory()() as db:
        assert db.query(AppSessionModel).count() == 0
        assert [row.session_id for row in db.query(WebPushSubscription).all()] == [persistent.id]
        assert db.query(IosPushToken).count() == 0
        assert db.query(IosLiveActivityToken).count() == 0
        assert db.query(SchoolAccountSession).count() == 0
    assert temporary.id not in store._sessions
    assert persistent.id not in store._sessions


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
