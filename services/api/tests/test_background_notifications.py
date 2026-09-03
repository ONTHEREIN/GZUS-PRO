import json

from fastapi.testclient import TestClient

from app import cloud_notifications
from app.cloud_notifications import run_background_notification_poll_once
from app.database import (
    BackgroundNotificationProfile,
    CredentialRevocation,
    NotificationDelivery,
    get_sync_session_factory,
)
from app.main import app
from app.sessions import SessionStore, credential_fingerprint, encrypt_device_credentials


class _StudentClient:
    def get_info(self) -> dict[str, str]:
        return {"studentId": "20260001"}

    def logout(self) -> None:
        return None


class _NotificationPollClient:
    def get_notices(self) -> list[dict[str, str]]:
        return [
            {"category": "教务", "title": "旧通知", "url": "https://example.test/old"},
            {"category": "教务", "title": "新通知", "url": "https://example.test/new"},
        ]

    def get_grades(self, _start: object, _end: object) -> list[dict[str, str]]:
        return []

    def get_exams(self, _start: object, _end: object) -> list[dict[str, str]]:
        return []

    def get_attendance(self, _start: object, _end: object) -> list[dict[str, str]]:
        return []


def test_failed_cloud_notification_is_retried_and_only_success_is_recorded(monkeypatch):
    client = _NotificationPollClient()
    monkeypatch.setattr(
        cloud_notifications,
        "_authenticated_client",
        lambda _credentials: (client, None),
    )
    attempts: list[str] = []

    def send_push(student_id: str, title: str, body: str, extras: dict) -> int:
        attempts.append(extras["url"])
        return 0 if len(attempts) == 1 else 1

    monkeypatch.setattr(cloud_notifications, "send_push_to_student", send_push)

    with get_sync_session_factory()() as db:
        db.add(
            BackgroundNotificationProfile(
                student_id="20260001",
                credential_fingerprint="test-fingerprint",
                encrypted_credentials="test-credentials",
                notice_keys_json=json.dumps(["教务|旧通知|https://example.test/old"]),
            )
        )
        db.commit()

    assert run_background_notification_poll_once() == {"processed": 1, "delivered": 0}
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        assert json.loads(profile.notice_keys_json) == ["教务|旧通知|https://example.test/old"]
        assert db.query(NotificationDelivery).count() == 0

    assert run_background_notification_poll_once() == {"processed": 1, "delivered": 1}
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        assert set(json.loads(profile.notice_keys_json)) == {
            "教务|旧通知|https://example.test/old",
            "教务|新通知|https://example.test/new",
        }
        delivery = db.query(NotificationDelivery).one()
        assert delivery.delivery_status == "delivered"
    assert attempts == ["https://example.test/new", "https://example.test/new"]


def _client() -> tuple[TestClient, str]:
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
    session = app.state.sessions.create(_StudentClient(), "测试同学", student_account="20260001")
    return TestClient(app), session.id


def test_background_notification_access_can_be_enabled_synced_and_revoked():
    client, session_id = _client()
    token = encrypt_device_credentials(
        "20260001", "password", "test-credential-id", "test-credential-key"
    )
    headers = {"X-Session-Id": session_id}

    enabled = client.put(
        "/notifications/background",
        json={
            "enabled": True,
            "credentialToken": token,
            "courseReminder": {
                "enabled": True,
                "beforeStartMinutes": 10,
                "beforeEndMinutes": 5,
                "firstWeekStart": "2026-09-01",
                "courses": [],
            },
        },
        headers=headers,
    )
    assert enabled.status_code == 200
    assert enabled.json()["enabled"] is True

    synced = client.put(
        "/notifications/course-reminders",
        json={
            "enabled": True,
            "beforeStartMinutes": 10,
            "beforeEndMinutes": 5,
            "firstWeekStart": "2026-09-01",
            "courses": [{"name": "高等数学", "weekday": 1, "startSection": 1, "endSection": 2, "weeks": [1, 2]}],
        },
        headers=headers,
    )
    assert synced.status_code == 200
    assert synced.json()["courseRemindersEnabled"] is True

    factory = get_sync_session_factory()
    with factory() as db:
        profile = db.query(BackgroundNotificationProfile).filter_by(student_id="20260001").one()
        assert profile.encrypted_credentials == token
        db.add(NotificationDelivery(student_id="20260001", event_key="course:1", notification_type="course_reminder"))
        db.commit()

    revoked = client.put("/notifications/background", json={"enabled": False}, headers=headers)
    assert revoked.status_code == 200
    assert revoked.json()["enabled"] is False
    with factory() as db:
        assert db.query(BackgroundNotificationProfile).count() == 0
        assert db.query(NotificationDelivery).count() == 0


def test_revoked_device_credential_removes_background_notification_profile():
    client, session_id = _client()
    credential_id = "revoked-device-credential"
    token = encrypt_device_credentials("20260001", "password", credential_id, "test-credential-key")
    response = client.put(
        "/notifications/background",
        json={"enabled": True, "credentialToken": token},
        headers={"X-Session-Id": session_id},
    )
    assert response.status_code == 200

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            CredentialRevocation(
                credential_fingerprint=credential_fingerprint(credential_id),
                reason="admin_kick",
            )
        )
        db.commit()

    assert run_background_notification_poll_once() == {"processed": 0, "delivered": 0}
    with factory() as db:
        assert db.query(BackgroundNotificationProfile).count() == 0
