"""共享学校会话清理的本地数据库集成检查；不访问学校或微信。"""

from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from app import database
from app.config import get_settings
from app.database import (
    AdminUser,
    AppSessionModel,
    BackgroundNotificationProfile,
    DeviceAuthorization,
    SchoolAccountSession,
    WechatBinding,
    get_sync_session_factory,
)
from app.main import create_app
from app.school_session_service import (
    SchoolSessionUnavailableError,
    account_school_session_lock,
    load_shared_school_clients,
    record_authenticated_session,
    release_if_unused,
    revoke_account_school_access,
)
from app.sessions import CredentialRevokedError, SessionStore


@pytest.mark.parametrize("operation", ["purge", "get", "logout"])
@pytest.mark.parametrize("reference", ["none", "background", "device", "wechat"])
def test_cleanup_respects_other_account_authorizations(operation: str, reference: str) -> None:
    """自然过期与退出均不能删除仍被其他有效授权引用的学校会话。"""
    account = "20260001"
    now = datetime.now(timezone.utc)
    shared = record_authenticated_session(account, None, "lifecycle-test-cookie", None, None, None)
    store = SessionStore(ttl_seconds=get_settings().session_ttl_seconds)
    session = store.create(None, student_account=account, school_session_version=shared.version)
    with get_sync_session_factory()() as db:
        row = db.get(AppSessionModel, session.id)
        assert row is not None
        if operation != "logout":
            row.last_active_at = now - timedelta(seconds=get_settings().session_ttl_seconds + 1)
        if reference == "background":
            db.add(BackgroundNotificationProfile(
                student_id=account,
                credential_fingerprint="other-background-grant",
                encrypted_credentials="test-ciphertext",
            ))
        elif reference == "device":
            db.add(DeviceAuthorization(
                token_digest="other-device-grant",
                student_account=account,
                installation_id="other-installation",
                login_method="sso",
                store_school_password=False,
                created_at=now,
                last_used_at=now,
            ))
        elif reference == "wechat":
            db.add(WechatBinding(
                student_id=account,
                openid_fingerprint="lifecycle-test-fingerprint",
                encrypted_openid="test-ciphertext",
                app_id="lifecycle-test-app",
            ))
        db.commit()

    if operation == "purge":
        store._purge_expired()
    elif operation == "get":
        assert store.get(session.id, touch=False, fresh=True) is None
    else:
        store.remove(session.id, None, None)

    with get_sync_session_factory()() as db:
        assert db.get(AppSessionModel, session.id) is None
        assert (db.query(SchoolAccountSession).count() == 1) == (reference != "none")
        assert db.query(WechatBinding).count() == (1 if reference == "wechat" else 0)


def test_revoked_device_does_not_retain_shared_school_session() -> None:
    account = "20260001"
    now = datetime.now(timezone.utc)
    record_authenticated_session(account, None, "lifecycle-test-cookie", None, None, None)
    with get_sync_session_factory()() as db:
        db.add(DeviceAuthorization(
            token_digest="revoked-device-grant",
            student_account=account,
            installation_id="revoked-installation",
            login_method="sso",
            store_school_password=False,
            created_at=now,
            last_used_at=now,
            revoked_at=now,
            revoked_reason="logout",
        ))
        db.commit()

    assert release_if_unused(account)
    with get_sync_session_factory()() as db:
        assert db.query(SchoolAccountSession).count() == 0


def test_admin_http_revocation_of_uncredentialed_session_removes_shared_access() -> None:
    application = create_app()
    store = application.state.sessions
    admin = store.create(None, student_account="20260000", is_admin=True)
    shared = record_authenticated_session("20260001", None, "test-cookie", None, None, None)
    target = store.create(None, student_account="20260001", school_session_version=shared.version)
    with get_sync_session_factory()() as db:
        db.add(AdminUser(student_id="20260000", role="owner"))
        db.add(WechatBinding(
            student_id="20260001", openid_fingerprint="test-fingerprint",
            encrypted_openid="test-ciphertext", app_id="test-app",
        ))
        db.commit()
    with TestClient(application) as client:
        response = client.post(
            f"/admin/sessions/{target.id}/revoke", headers={"X-Session-Id": admin.id},
        )
    assert response.status_code == 200, response.text
    with get_sync_session_factory()() as db:
        assert db.query(WechatBinding).count() == 1
        assert db.query(SchoolAccountSession).count() == 0
        assert db.get(AppSessionModel, target.id).revoked_at is not None


def test_parallel_cleanup_and_admin_revocation_cannot_retain_school_access() -> None:
    account = "20260001"
    record_authenticated_session(account, None, "test-cookie", None, None, None)
    with get_sync_session_factory()() as db:
        db.add(WechatBinding(
            student_id=account, openid_fingerprint="test-fingerprint",
            encrypted_openid="test-ciphertext", app_id="test-app",
        ))
        db.commit()
    with ThreadPoolExecutor(max_workers=2) as executor:
        with account_school_session_lock(account):
            cleanup = executor.submit(release_if_unused, account)
            revoke = executor.submit(revoke_account_school_access, account)
        cleanup.result(timeout=5)
        revoke.result(timeout=5)
    with get_sync_session_factory()() as db:
        assert db.query(SchoolAccountSession).count() == 0
        assert db.query(WechatBinding).count() == 1


def test_legacy_authentication_timestamp_migration_does_not_extend_retention(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    record_authenticated_session("20260001", None, "test-cookie", None, None, None)
    created_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=31)
    with get_sync_session_factory()() as db:
        db.query(SchoolAccountSession).update({"created_at": created_at})
        db.commit()
    engine = database.get_sync_engine()
    with engine.begin() as connection:
        connection.execute(text("ALTER TABLE school_account_sessions DROP COLUMN authenticated_at"))
    monkeypatch.setattr(database, "_db_initialized", False)
    database.init_db()
    database.init_db()
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).one()
        assert row.authenticated_at == row.created_at
        assert row.authenticated_at.replace(tzinfo=None) == created_at


def test_account_revocation_prevents_other_old_credentials_from_recovering_after_reauthentication(
) -> None:
    account = "20260001"
    shared = record_authenticated_session(account, None, "test-cookie", None, None, None)
    store = SessionStore(ttl_seconds=get_settings().session_ttl_seconds)
    for fingerprint in ("first-device", "second-device"):
        store.create(
            None, student_account=account, credential_fingerprint=fingerprint,
            school_session_version=shared.version,
        )
    revoke_account_school_access(account)
    renewed = record_authenticated_session(account, None, "new-cookie", None, None, None)
    for fingerprint in ("first-device", "second-device"):
        assert store.is_credential_revoked(fingerprint)
        with pytest.raises(CredentialRevokedError):
            store.create(
                None, student_account=account, credential_fingerprint=fingerprint,
                school_session_version=renewed.version,
            )


def test_account_revocation_retains_binding_but_removes_school_access() -> None:
    """无设备凭据的微信会话同样必须服从账号级撤销。"""
    account = "20260001"
    shared = record_authenticated_session(account, None, "lifecycle-test-cookie", None, None, None)
    store = SessionStore(ttl_seconds=get_settings().session_ttl_seconds)
    session = store.create(None, student_account=account, school_session_version=shared.version)
    with get_sync_session_factory()() as db:
        db.add(WechatBinding(
            student_id=account,
            openid_fingerprint="lifecycle-test-fingerprint",
            encrypted_openid="test-ciphertext",
            app_id="lifecycle-test-app",
        ))
        db.commit()

    revoke_account_school_access(account)

    with get_sync_session_factory()() as db:
        assert db.query(WechatBinding).count() == 1
        assert db.query(SchoolAccountSession).count() == 0
        row = db.get(AppSessionModel, session.id)
        assert row is not None
        assert row.revoked_at is not None
        assert row.revoked_reason == "admin_kick"


@pytest.mark.parametrize("age_days", [29, 30, 31])
def test_binding_only_retention_uses_authentication_time_and_cleans_without_app_sessions(
    age_days: int,
) -> None:
    account = "20260001"
    now = datetime.now(timezone.utc)
    record_authenticated_session(account, None, "lifecycle-test-cookie", None, None, None)
    with get_sync_session_factory()() as db:
        db.add(WechatBinding(
            student_id=account,
            openid_fingerprint="lifecycle-test-fingerprint",
            encrypted_openid="test-ciphertext",
            app_id="lifecycle-test-app",
        ))
        row = db.query(SchoolAccountSession).one()
        row.authenticated_at = now - timedelta(days=age_days)
        row.last_used_at = now
        row.updated_at = now
        db.commit()

    # 不依赖 AppSession 存在，也不能通过普通读取把 30 天期限向后滚动。
    SessionStore(ttl_seconds=get_settings().session_ttl_seconds)._purge_expired()

    with get_sync_session_factory()() as db:
        assert db.query(WechatBinding).count() == 1
        assert db.query(SchoolAccountSession).count() == (1 if age_days < 30 else 0)


def test_reauthentication_renews_retention_but_marking_invalid_does_not() -> None:
    from app.school_session_service import mark_school_session_invalid

    account = "20260001"
    record_authenticated_session(account, None, "lifecycle-test-cookie", None, None, None)
    with get_sync_session_factory()() as db:
        db.add(WechatBinding(
            student_id=account,
            openid_fingerprint="lifecycle-test-fingerprint",
            encrypted_openid="test-ciphertext",
            app_id="lifecycle-test-app",
        ))
        row = db.query(SchoolAccountSession).one()
        row.authenticated_at = datetime.now(timezone.utc) - timedelta(days=31)
        db.commit()
    with pytest.raises(SchoolSessionUnavailableError, match="微信恢复保留期"):
        load_shared_school_clients(account)

    record_authenticated_session(account, None, "renewed-test-cookie", None, None, None)
    assert release_if_unused(account) is False
    mark_school_session_invalid(account)
    with pytest.raises(SchoolSessionUnavailableError, match="已过期"):
        load_shared_school_clients(account)
    assert release_if_unused(account)
    with get_sync_session_factory()() as db:
        assert db.query(WechatBinding).count() == 1
        assert db.query(SchoolAccountSession).count() == 0
