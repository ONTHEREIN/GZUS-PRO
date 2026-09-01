import json
import base64

import pytest
import httpx
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import apns_service
from app.database import IosPushToken, get_sync_session_factory
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


@pytest.fixture
def client():
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
    return TestClient(app)


class TestPushRoutes:
    def test_native_registration_routes_are_removed(self, client):
        register_response = client.post("/push/register", json={"registrationId": "abc123"})
        unregister_response = client.post("/push/unregister", json={})

        assert register_response.status_code == 404
        assert unregister_response.status_code == 404

    def test_web_push_config_remains_available(self, client):
        response = client.get("/push/web/config")

        assert response.status_code == 200
        assert "enabled" in response.json()

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

    def test_poll_receives_queued_test_message(self, client):
        session_response = client.post("/push/test-session")
        session_id = session_response.json()["sessionId"]

        test_response = client.post(
            "/push/test",
            json={"title": "后台测试", "body": "后台消息"},
            headers={"X-Session-Id": session_id},
        )
        assert test_response.status_code == 200

        poll_response = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert poll_response.status_code == 200
        messages = poll_response.json()["messages"]
        assert len(messages) == 1
        assert messages[0]["title"] == "后台测试"
        assert messages[0]["body"] == "后台消息"

        empty_response = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert empty_response.json()["messages"] == []


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
