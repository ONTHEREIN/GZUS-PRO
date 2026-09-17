from datetime import datetime, timezone

from app import cloud_notifications
from app.cas_auto_login import is_school_session_limit_error
from app.cloud_notifications import run_background_notification_poll_once
from app.database import (
    AppSessionModel,
    BackgroundNotificationProfile,
    NotificationDelivery,
    SchoolAccountSession,
    get_sync_session_factory,
)
from app.sessions import encrypt_credentials
from app import school_session_service


class _FakeSchoolClient:
    def get_jwxt_cookies_string(self) -> str:
        return "JSESSIONID=shared"


def test_background_poll_retries_authentication_failure_once(monkeypatch):
    attempts = 0

    def authenticate(_credentials: str):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            from app.school_client import AuthenticationError

            raise AuthenticationError("登录状态已失效，请重新登录")
        return _FakeSchoolClient(), None

    monkeypatch.setattr(cloud_notifications, "_authenticated_client", authenticate)
    monkeypatch.setattr(cloud_notifications, "_poll_profile_once", lambda *_args: 0)
    with get_sync_session_factory()() as db:
        profile = BackgroundNotificationProfile(
            student_id="20260001",
            credential_fingerprint="fingerprint",
            encrypted_credentials="credentials",
        )
        db.add(profile)
        db.commit()

    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        assert cloud_notifications._poll_profile(profile) == 0
    assert attempts == 2


def test_authenticated_school_session_is_encrypted_and_rotates_version(monkeypatch):
    monkeypatch.setattr(
        school_session_service,
        "_rebuild_school_client",
        lambda _cookies, account=None, validate_cookies=False: _FakeSchoolClient(),
    )
    first = school_session_service.record_authenticated_session(
        "20260001", "测试同学", "JSESSIONID=one", "EHALL=one", "Bearer one", None
    )
    second = school_session_service.record_authenticated_session(
        "20260001", "测试同学", "JSESSIONID=two", "EHALL=two", "Bearer two", None
    )

    assert first.version == 1
    assert second.version == 2
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id="20260001").one()
        assert row.jwxt_cookies != "JSESSIONID=two"
        assert row.ehall_cookies != "EHALL=two"
        assert row.ehall_auth_token != "Bearer two"


def test_background_reuses_shared_session_and_logs_in_once(monkeypatch):
    attempts: list[str] = []

    def fake_login(account: str, _password: str):
        attempts.append(account)
        return account, "JSESSIONID=shared", None, None

    monkeypatch.setattr(school_session_service, "_cas_login", fake_login)
    monkeypatch.setattr(
        school_session_service,
        "_rebuild_school_client",
        lambda _cookies, account=None, validate_cookies=False: _FakeSchoolClient(),
    )
    credentials = encrypt_credentials("20260001", "password", "test-credential-key")

    school_session_service.ensure_background_clients("20260001", credentials)
    school_session_service.ensure_background_clients("20260001", credentials)

    assert attempts == ["20260001"]


def test_new_frontend_session_references_shared_version_without_copying_cookies(monkeypatch):
    from app.sessions import SessionStore

    monkeypatch.setattr(
        school_session_service,
        "_rebuild_school_client",
        lambda _cookies, account=None, validate_cookies=False: _FakeSchoolClient(),
    )
    shared = school_session_service.record_authenticated_session(
        "20260001", "测试同学", "JSESSIONID=one", None, None, None
    )
    store = SessionStore(ttl_seconds=7200)
    session = store.create(
        _FakeSchoolClient(),
        "测试同学",
        student_account="20260001",
        school_session_version=shared.version,
    )
    with get_sync_session_factory()() as db:
        row = db.query(AppSessionModel).filter_by(id=session.id).one()
        assert row.jwxt_cookies is None
        assert row.school_session_version == shared.version
    restored = SessionStore(ttl_seconds=7200).get(session.id, touch=False)
    assert restored is not None
    assert restored.client is not None


def test_school_session_limit_classifier_does_not_match_password_or_network_errors():
    assert is_school_session_limit_error("登录设备数已达到上限", None)
    assert is_school_session_limit_error("too many login devices", "DEVICE_LIMIT")
    assert not is_school_session_limit_error("密码错误", "PASSERROR")
    assert not is_school_session_limit_error("CAS 暂不可用", None)


def test_device_limit_suspends_profile_and_notifies_once(monkeypatch):
    from app.school_session_service import SchoolSessionLimitError

    monkeypatch.setattr(
        cloud_notifications,
        "_authenticated_client",
        lambda _credentials: (_ for _ in ()).throw(
            SchoolSessionLimitError("20260001", "校方设备或会话数达到上限")
        ),
    )
    pushes: list[str] = []
    monkeypatch.setattr(
        cloud_notifications,
        "send_push_to_student",
        lambda _student, title, _body, _extras: pushes.append(title) or 1,
    )
    with get_sync_session_factory()() as db:
        db.add(
            BackgroundNotificationProfile(
                student_id="20260001",
                credential_fingerprint="fingerprint",
                encrypted_credentials="credentials",
            )
        )
        db.commit()

    assert run_background_notification_poll_once() == {"processed": 1, "delivered": 0}
    assert run_background_notification_poll_once() == {"processed": 1, "delivered": 0}
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        assert profile.suspended_at is not None
        assert profile.next_retry_at is not None
        assert profile.next_retry_at > datetime.now(timezone.utc).replace(tzinfo=None)
        assert db.query(NotificationDelivery).count() == 1
    assert pushes == ["后台监测已暂停"]
