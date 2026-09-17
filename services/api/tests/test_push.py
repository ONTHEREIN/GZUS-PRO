import json
import base64
from datetime import datetime, timedelta, timezone

import pytest
import httpx
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import apns_service
from app import push as push_service
from app.database import (
    IosLiveActivityToken,
    IosPushToken,
    NotificationDelivery,
    WebPushSubscription,
    get_sync_session_factory,
)
from app.main import app
from app.sessions import SessionStore


def test_web_push_public_key_is_browser_base64url(monkeypatch):
    from py_vapid import Vapid
    from app.config import get_settings
    from app.push import web_push_public_key

    vapid = Vapid()
    vapid.generate_keys()
    raw = vapid.private_key.private_numbers().private_value.to_bytes(32, "big")
    monkeypatch.setenv("WEB_PUSH_VAPID_PRIVATE_KEY", base64.urlsafe_b64encode(raw).rstrip(b"=").decode())
    get_settings.cache_clear()
    public_key = web_push_public_key()

    assert public_key is not None
    assert len(public_key) == 87
    assert all(character.isalnum() or character in "-_" for character in public_key)


def test_push_keeps_success_from_one_channel_when_the_other_raises(monkeypatch):
    def raise_web_push(*_args, **_kwargs):
        raise RuntimeError("web push unavailable")

    monkeypatch.setattr(push_service, "send_web_push_to_student", raise_web_push)
    monkeypatch.setattr(push_service, "send_apns_to_student", lambda *_args, **_kwargs: 1)

    assert push_service.send_push_to_student("20260001", "测试", "通知") == 1


def test_push_sends_regular_apns_when_live_activity_succeeds(monkeypatch):
    calls: list[str] = []

    monkeypatch.setattr(push_service, "send_web_push_to_student", lambda *_args, **_kwargs: 0)
    monkeypatch.setattr(
        push_service,
        "send_apns_to_student",
        lambda *_args, **_kwargs: calls.append("apns") or 1,
    )
    monkeypatch.setattr(
        push_service,
        "send_live_activity_to_student",
        lambda *_args, **_kwargs: calls.append("live_activity") or 1,
    )

    delivered = push_service.send_push_to_student(
        "20260001",
        "新通知",
        "通知内容",
        {"type": "new_notice", "liveUpdate": True},
    )

    assert delivered == 2
    assert delivered.regular_delivered == 1
    assert delivered.live_activity_delivered == 1
    assert calls == ["apns", "live_activity"]


@pytest.fixture
def client():
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
    return TestClient(app)


class TestPushRoutes:
    def test_live_activity_routes_are_registered(self):
        paths = set(app.openapi()["paths"])

        assert "/push/ios/live-activity-tokens" in paths
        assert "/push/ios/live-activity-tokens/activity/unregister" in paths
        assert "/push/ios/live-activity-tokens/unregister" in paths

    def test_native_registration_routes_are_removed(self, client):
        register_response = client.post("/push/register", json={"registrationId": "abc123"})
        unregister_response = client.post("/push/unregister", json={})

        assert register_response.status_code == 404
        assert unregister_response.status_code == 404

    def test_web_push_config_remains_available(self, client):
        response = client.get("/push/web/config")

        assert response.status_code == 200
        assert "enabled" in response.json()

    def test_web_push_unregistration_only_removes_current_endpoint(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        headers = {"X-Session-Id": session_id}
        endpoints = [
            "https://push.example.test/device-a",
            "https://push.example.test/device-b",
        ]
        for endpoint in endpoints:
            response = client.post(
                "/push/web/register",
                json={
                    "endpoint": endpoint,
                    "keys": {"p256dh": "p256dh", "auth": "auth"},
                },
                headers=headers,
            )
            assert response.status_code == 200

        response = client.post(
            "/push/web/unregister",
            json={"endpoint": endpoints[0]},
            headers=headers,
        )

        assert response.status_code == 200
        with get_sync_session_factory()() as db:
            rows = db.query(WebPushSubscription).all()
            assert [row.endpoint for row in rows] == [endpoints[1]]

    def test_ios_token_registration_updates_current_device(self, client):
        session_response = client.post("/push/test-session")
        session_id = session_response.json()["sessionId"]
        token = "a" * 64

        register_response = client.post(
            "/push/ios/register",
            json={"deviceToken": token, "environment": "sandbox"},
            headers={"X-Session-Id": session_id},
        )

        assert register_response.status_code == 200
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(IosPushToken).one()
            assert row.student_id == "test-student"
            assert row.device_token == token
            assert row.environment == "sandbox"

        unregister_response = client.post(
            "/push/ios/unregister",
            json={"deviceToken": token, "environment": "sandbox"},
            headers={"X-Session-Id": session_id},
        )
        assert unregister_response.status_code == 200
        with factory() as db:
            assert db.query(IosPushToken).count() == 0

    def test_ios_course_schedule_sync_records_local_coverage(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        token = "b" * 64
        headers = {"X-Session-Id": session_id}
        client.post(
            "/push/ios/register",
            json={"deviceToken": token, "environment": "production"},
            headers=headers,
        )

        response = client.post(
            "/push/ios/course-schedule",
            json={
                "deviceToken": token,
                "environment": "production",
                "eventKeys": ["course:start:高等数学:2026-09-15:08:50"],
                "validUntil": "2026-09-29T00:00:00Z",
            },
            headers=headers,
        )

        assert response.status_code == 200
        with get_sync_session_factory()() as db:
            row = db.query(IosPushToken).one()
            assert json.loads(row.course_local_event_keys_json) == [
                "course:start:高等数学:2026-09-15:08:50"
            ]
            assert row.course_local_valid_until is not None

    def test_ios_token_registration_moves_device_to_new_student(self, client):
        first_session_id = client.post("/push/test-session").json()["sessionId"]
        token = "c" * 64
        first_response = client.post(
            "/push/ios/register",
            json={"deviceToken": token, "environment": "production"},
            headers={"X-Session-Id": first_session_id},
        )
        assert first_response.status_code == 200

        class _SecondStudentClient:
            def get_info(self) -> dict[str, str]:
                return {"studentId": "second-student"}

            def logout(self) -> None:
                pass

        second_session = client.app.state.sessions.create(_SecondStudentClient(), "第二位测试用户")
        second_response = client.post(
            "/push/ios/register",
            json={"deviceToken": token, "environment": "production"},
            headers={"X-Session-Id": second_session.id},
        )
        assert second_response.status_code == 200

        factory = get_sync_session_factory()
        with factory() as db:
            rows = db.query(IosPushToken).all()
            assert len(rows) == 1
            assert rows[0].student_id == "second-student"

    def test_live_activity_token_registration_is_student_scoped(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        start_token = "e" * 64
        activity_token = "f" * 64
        headers = {"X-Session-Id": session_id}

        start_response = client.post(
            "/push/ios/live-activity-tokens",
            json={
                "tokenType": "start",
                "token": start_token,
                "environment": "sandbox",
                "activityType": "new_notice",
            },
            headers=headers,
        )
        activity_response = client.post(
            "/push/ios/live-activity-tokens",
            json={
                "tokenType": "activity",
                "token": activity_token,
                "environment": "sandbox",
                "activityId": "notice:test",
                "activityType": "new_notice",
            },
            headers=headers,
        )

        assert start_response.status_code == 200
        assert activity_response.status_code == 200
        with get_sync_session_factory()() as db:
            rows = db.query(IosLiveActivityToken).all()
            assert {row.token_type for row in rows} == {"start", "activity"}
            assert {row.student_id for row in rows} == {"test-student"}
            activity_row = next(row for row in rows if row.token_type == "activity")
            assert activity_row.expires_at is not None
            assert timedelta(hours=5) < activity_row.expires_at - activity_row.created_at < timedelta(hours=7)

        unregister_response = client.post(
            "/push/ios/live-activity-tokens/unregister",
            headers=headers,
        )
        assert unregister_response.status_code == 200
        with get_sync_session_factory()() as db:
            assert db.query(IosLiveActivityToken).count() == 0

    def test_live_activity_token_rotation_replaces_only_same_device_activity(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        headers = {"X-Session-Id": session_id}
        base = {
            "tokenType": "activity",
            "environment": "production",
            "activityId": "ecard:today",
            "activityType": "ecard_reminder",
            "deviceId": "device-a",
            "expiresAt": "2026-09-17T09:00:00Z",
        }
        first = client.post(
            "/push/ios/live-activity-tokens",
            json={**base, "token": "a" * 64},
            headers=headers,
        )
        rotated = client.post(
            "/push/ios/live-activity-tokens",
            json={**base, "token": "b" * 64},
            headers=headers,
        )
        second_device = client.post(
            "/push/ios/live-activity-tokens",
            json={**base, "token": "c" * 64, "deviceId": "device-b"},
            headers=headers,
        )

        assert first.status_code == rotated.status_code == second_device.status_code == 200
        with get_sync_session_factory()() as db:
            rows = db.query(IosLiveActivityToken).order_by(IosLiveActivityToken.device_id).all()
            assert [(row.device_id, row.token) for row in rows] == [
                ("device-a", "b" * 64),
                ("device-b", "c" * 64),
            ]
            assert rows[0].expires_at is not None

        unregistered = client.post(
            "/push/ios/live-activity-tokens/activity/unregister",
            json={
                "environment": "production",
                "activityId": "ecard:today",
                "deviceId": "device-a",
            },
            headers=headers,
        )
        assert unregistered.status_code == 200
        with get_sync_session_factory()() as db:
            rows = db.query(IosLiveActivityToken).all()
            assert [(row.device_id, row.token) for row in rows] == [("device-b", "c" * 64)]

    def test_bulk_live_activity_unregister_is_scoped_to_device(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        headers = {"X-Session-Id": session_id}
        for device_id, token in (("device-a", "d" * 64), ("device-b", "e" * 64)):
            response = client.post(
                "/push/ios/live-activity-tokens",
                json={
                    "tokenType": "activity",
                    "token": token,
                    "environment": "production",
                    "activityId": "notice:today",
                    "activityType": "new_notice",
                    "deviceId": device_id,
                },
                headers=headers,
            )
            assert response.status_code == 200

        response = client.post(
            "/push/ios/live-activity-tokens/unregister",
            json={"deviceId": "device-a"},
            headers=headers,
        )

        assert response.status_code == 200
        with get_sync_session_factory()() as db:
            rows = db.query(IosLiveActivityToken).all()
            assert [(row.device_id, row.token) for row in rows] == [("device-b", "e" * 64)]

    def test_poll_receives_queued_test_message(self, client):
        session_response = client.post("/push/test-session")
        session_id = session_response.json()["sessionId"]

        test_response = client.post(
            "/push/test",
            json={"title": "后台测试", "body": "后台消息"},
            headers={"X-Session-Id": session_id},
        )
        assert test_response.status_code == 200
        assert test_response.json()["delivered_channels"] == "0"
        assert test_response.json()["delivery_status"] == "queued_only"

        poll_response = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert poll_response.status_code == 200
        messages = poll_response.json()["messages"]
        assert len(messages) == 1
        assert messages[0]["title"] == "后台测试"
        assert messages[0]["body"] == "后台消息"

        empty_response = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert empty_response.json()["messages"] == []

    def test_notification_events_are_persisted_and_acknowledged_per_installation(self, client):
        session_id = client.post("/push/test-session").json()["sessionId"]
        with get_sync_session_factory()() as db:
            db.add(NotificationDelivery(
                student_id="test-student",
                event_key="grade:test:90",
                notification_type="grade_update",
                title="成绩更新",
                body="高等数学：90",
                extras_json=json.dumps({"type": "grade_update", "targetTab": "grades"}),
                expires_at=datetime.now(timezone.utc) + timedelta(days=30),
            ))
            db.commit()

        headers = {
            "X-Session-Id": session_id,
            "X-Installation-Id": "android-test-installation",
        }
        events = client.get("/notifications/events", headers=headers)
        assert events.status_code == 200
        assert events.json()["events"][0]["id"] == "grade:test:90"

        pending = client.get("/notifications/events/pending", headers=headers)
        assert [item["id"] for item in pending.json()["events"]] == ["grade:test:90"]
        presented = client.post(
            "/notifications/events/grade%3Atest%3A90/presented",
            headers=headers,
        )
        assert presented.status_code == 200
        assert client.get("/notifications/events/pending", headers=headers).json()["events"] == []

        read = client.post(
            "/notifications/events/grade%3Atest%3A90/read",
            headers={"X-Session-Id": session_id},
        )
        assert read.status_code == 200
        assert client.get("/notifications/events", headers=headers).json()["events"][0]["readAt"]


def test_apns_payload_keeps_only_notification_routing_metadata():
    payload = apns_service.build_apns_payload(
        "成绩更新",
        "高等数学成绩已发布",
        {
            "type": "grade_update",
            "url": "/grades",
            "ignored": {"nested": "value"},
        },
    )

    decoded = json.loads(payload)
    assert decoded["aps"]["alert"]["title"] == "成绩更新"
    assert decoded["extras"] == {"type": "grade_update", "url": "/grades"}
    assert len(payload) <= 4096


def test_apns_invalid_token_is_removed(monkeypatch):
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            IosPushToken(
                student_id="20260001",
                device_token="b" * 64,
                environment="production",
            )
        )
        db.commit()

    monkeypatch.setattr(apns_service, "is_apns_enabled", lambda: True)
    monkeypatch.setattr(apns_service, "_credentials", lambda _: object())

    def _raise_unregistered(*_args):
        raise apns_service.ApnsUnregisteredError("token expired")

    monkeypatch.setattr(apns_service, "_send_with_retry", _raise_unregistered)

    apns_service.send_apns_to_student("20260001", "测试", "测试通知", {"type": "test"})

    with factory() as db:
        assert db.query(IosPushToken).count() == 0


def test_apns_token_for_old_bundle_is_removed(monkeypatch):
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            IosPushToken(
                student_id="20260001",
                device_token="c" * 64,
                environment="sandbox",
            )
        )
        db.commit()

    monkeypatch.setattr(apns_service, "is_apns_enabled", lambda: True)
    monkeypatch.setattr(apns_service, "_credentials", lambda _: object())

    def _raise_old_bundle(*_args):
        raise apns_service.ApnsUnregisteredError("DeviceTokenNotForTopic")

    monkeypatch.setattr(apns_service, "_send_with_retry", _raise_old_bundle)

    apns_service.send_apns_to_student("20260001", "测试", "测试通知", {"type": "test"})

    with factory() as db:
        assert db.query(IosPushToken).filter_by(environment="sandbox").count() == 0


def test_apns_course_reminder_skips_events_covered_by_ios_local_schedule(monkeypatch):
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            IosPushToken(
                student_id="20260001",
                device_token="d" * 64,
                environment="production",
                course_local_event_keys_json='["course:start:高等数学:2026-09-15:08:50"]',
                course_local_valid_until=datetime.now(timezone.utc) + timedelta(hours=1),
            )
        )
        db.commit()

    calls: list[str] = []
    monkeypatch.setattr(apns_service, "is_apns_enabled", lambda: True)
    monkeypatch.setattr(apns_service, "_credentials", lambda _: object())
    monkeypatch.setattr(apns_service, "_send_with_retry", lambda *_args: calls.append("sent"))

    covered = apns_service.send_apns_to_student(
        "20260001",
        "即将上课",
        "课程提醒",
        {
            "type": "course_reminder",
            "eventKey": "course:start:高等数学:2026-09-15:08:50",
        },
    )
    fallback = apns_service.send_apns_to_student(
        "20260001",
        "即将上课",
        "课程提醒",
        {
            "type": "course_reminder",
            "eventKey": "course:end:高等数学:2026-09-15:09:35",
        },
    )

    assert covered == 0
    assert fallback == 1
    assert calls == ["sent"]


def test_live_activity_payload_supports_start_update_and_end():
    for action in ("start", "update", "end"):
        payload = apns_service.build_live_activity_payload(
            action,
            "考试提醒",
            "高等数学即将开始",
            {
                "id": "exam:1",
                "type": "exam_reminder",
                "targetTab": "exams",
                "startTime": 1_700_000_000_000,
                "endTime": 1_700_003_600_000,
                "shortCriticalText": "考试",
                "ongoing": True,
            },
        )
        decoded = json.loads(payload)
        assert decoded["aps"]["event"] == action
        assert decoded["aps"]["content-state"]["endEpochMillis"] == 1_700_003_600_000
        if action == "start":
            assert decoded["input-push-token"] == 1
            assert decoded["aps"]["attributes-type"] == "GzusLiveActivityAttributes"
            assert decoded["aps"]["attributes"]["targetTab"] == "exams"
        else:
            assert "attributes" not in decoded
        assert len(payload) <= 4096


def test_live_activity_start_prunes_expired_activity_tokens_and_allows_parallel_events(monkeypatch):
    now = datetime.now(timezone.utc)
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="activity",
            token="a" * 64,
            environment="production",
            activity_id="course:old",
            activity_type="course_reminder",
            expires_at=now - timedelta(minutes=1),
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="start",
            token="b" * 64,
            environment="production",
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="activity",
            token="c" * 64,
            environment="production",
            activity_id="course:active",
            activity_type="course_reminder",
            expires_at=now + timedelta(hours=1),
        ))
        db.commit()

    monkeypatch.setattr(apns_service, "is_apns_enabled", lambda: True)
    monkeypatch.setattr(apns_service, "_credentials", lambda _settings: object())
    sent: list[bytes] = []
    monkeypatch.setattr(
        apns_service,
        "_send_live_activity_with_retry",
        lambda _credentials, _token, _environment, payload: sent.append(payload),
    )

    delivered = apns_service.send_live_activity_to_student(
        "20260001",
        "start",
        "水电提醒",
        "电费余额偏低",
        {"id": "ecard:new", "type": "ecard_reminder"},
    )

    assert delivered == 1
    assert len(sent) == 1
    with factory() as db:
        assert db.query(IosLiveActivityToken).filter_by(token="a" * 64).count() == 0
        assert db.query(IosLiveActivityToken).filter_by(token="c" * 64).count() == 1


def test_live_activity_end_removes_successfully_ended_activity_tokens(monkeypatch):
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="activity",
            token="c" * 64,
            environment="production",
            activity_id="ecard:old",
            activity_type="ecard_reminder",
            device_id="device-a",
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="activity",
            token="d" * 64,
            environment="production",
            activity_id="ecard:old",
            activity_type="ecard_reminder",
            device_id="device-b",
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        ))
        db.commit()

    monkeypatch.setattr(apns_service, "is_apns_enabled", lambda: True)
    monkeypatch.setattr(apns_service, "_credentials", lambda _settings: object())
    sent: list[str] = []
    monkeypatch.setattr(
        apns_service,
        "_send_live_activity_with_retry",
        lambda _credentials, token, _environment, _payload: sent.append(token),
    )

    delivered = apns_service.send_live_activity_to_student(
        "20260001",
        "end",
        "",
        "",
        {"id": "ecard:old", "type": "ecard_reminder", "dismissImmediately": True},
    )

    assert delivered == 2
    assert set(sent) == {"c" * 64, "d" * 64}
    with factory() as db:
        assert db.query(IosLiveActivityToken).count() == 0


def test_live_activity_request_uses_liveactivity_topic_and_push_type(monkeypatch):
    requests: list[tuple[str, bytes, dict[str, str]]] = []

    class _FakeClient:
        def __init__(self, *, http2: bool, timeout: float) -> None:
            assert http2 is True
            assert timeout == 10.0

        def __enter__(self):
            return self

        def __exit__(self, *_args) -> None:
            pass

        def post(self, url: str, *, content: bytes, headers: dict[str, str]) -> httpx.Response:
            requests.append((url, content, headers))
            return httpx.Response(200, request=httpx.Request("POST", url))

    monkeypatch.setattr(apns_service.httpx, "Client", _FakeClient)
    credentials = apns_service._ApnsCredentials(
        key_id="ABC123",
        team_id="6863N22CPT",
        bundle_id="cn.gzus.pro",
        private_key=ec.generate_private_key(ec.SECP256R1()),
    )

    apns_service._send_live_activity_once(
        credentials,
        "a" * 64,
        "sandbox",
        apns_service.build_live_activity_payload("start", "测试", "通知", {"id": "1"}),
    )

    assert requests[0][0].startswith("https://api.sandbox.push.apple.com/3/device/")
    assert requests[0][2]["apns-topic"] == "cn.gzus.pro.push-type.liveactivity"
    assert requests[0][2]["apns-push-type"] == "liveactivity"


def test_apns_request_uses_http2_topic_and_alert_headers(monkeypatch):
    requests: list[tuple[str, bytes, dict[str, str]]] = []

    class _FakeClient:
        def __init__(self, *, http2: bool, timeout: float) -> None:
            assert http2 is True
            assert timeout == 10.0

        def __enter__(self):
            return self

        def __exit__(self, *_args) -> None:
            pass

        def post(self, url: str, *, content: bytes, headers: dict[str, str]) -> httpx.Response:
            requests.append((url, content, headers))
            return httpx.Response(200, request=httpx.Request("POST", url))

    monkeypatch.setattr(apns_service.httpx, "Client", _FakeClient)
    credentials = apns_service._ApnsCredentials(
        key_id="ABC123",
        team_id="6863N22CPT",
        bundle_id="cn.gzus.pro",
        private_key=ec.generate_private_key(ec.SECP256R1()),
    )

    apns_service._send_once(
        credentials,
        "d" * 64,
        "sandbox",
        apns_service.build_apns_payload("测试", "通知", {"type": "test"}),
    )

    assert requests[0][0].startswith("https://api.sandbox.push.apple.com/3/device/")
    assert requests[0][2]["apns-topic"] == "cn.gzus.pro"
    assert requests[0][2]["apns-push-type"] == "alert"
