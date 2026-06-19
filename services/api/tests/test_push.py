import pytest
from fastapi.testclient import TestClient

from app.database import AppSessionModel, PushRegistration, get_sync_session_factory
from app.main import app
from app.sessions import SessionStore


@pytest.fixture
def client():
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
    return TestClient(app)


def _get_session_row(session_id: str) -> AppSessionModel:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
        assert row is not None
        return row


def _count_push_registration(registration_id: str) -> int:
    factory = get_sync_session_factory()
    with factory() as db:
        return (
            db.query(PushRegistration)
            .filter(PushRegistration.registration_id == registration_id)
            .count()
        )


@pytest.fixture
def auth_session(client):
    resp = client.post("/auth/login", json={"account": "test", "password": "test"})
    if resp.status_code == 401:
        pytest.skip("requires valid school credentials")
    data = resp.json()
    return data.get("sessionId") or resp.headers.get("x-session-id", "")


class TestPushRegister:
    def test_register_without_session(self, client):
        resp = client.post("/push/register", json={"registrationId": "abc123"})
        assert resp.status_code == 401

    def test_unregister_without_session(self, client):
        resp = client.post("/push/unregister", json={})
        assert resp.status_code == 401

    def test_poll_receives_queued_test_message(self, client):
        session_resp = client.post("/push/test-session")
        session_id = session_resp.json()["sessionId"]

        test_resp = client.post(
            "/push/test",
            json={"title": "后台测试", "body": "后台消息"},
            headers={"X-Session-Id": session_id},
        )
        assert test_resp.status_code == 200

        poll_resp = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert poll_resp.status_code == 200
        messages = poll_resp.json()["messages"]
        assert len(messages) == 1
        assert messages[0]["title"] == "后台测试"
        assert messages[0]["body"] == "后台消息"

        empty_resp = client.get("/push/poll", headers={"X-Session-Id": session_id})
        assert empty_resp.json()["messages"] == []

    def test_unregister_keeps_session_push_platform_non_null(self, client):
        session_resp = client.post("/push/test-session")
        session_id = session_resp.json()["sessionId"]

        register_resp = client.post(
            "/push/register",
            json={"registrationId": "abc123", "platform": "android"},
            headers={"X-Session-Id": session_id},
        )
        assert register_resp.status_code == 200

        unregister_resp = client.post(
            "/push/unregister",
            json={},
            headers={"X-Session-Id": session_id},
        )
        assert unregister_resp.status_code == 200
        session = client.app.state.sessions.get(session_id)
        assert session.push_registration_id is None
        assert session.push_platform == "android"

        row = _get_session_row(session_id)
        assert row.push_registration_id is None
        assert row.push_platform == "android"
        assert _count_push_registration("abc123") == 0

    def test_unregister_preserves_existing_push_platform(self, client):
        session_resp = client.post("/push/test-session")
        session_id = session_resp.json()["sessionId"]

        register_resp = client.post(
            "/push/register",
            json={"registrationId": "ios123", "platform": "ios"},
            headers={"X-Session-Id": session_id},
        )
        assert register_resp.status_code == 200

        unregister_resp = client.post(
            "/push/unregister",
            json={},
            headers={"X-Session-Id": session_id},
        )
        assert unregister_resp.status_code == 200

        row = _get_session_row(session_id)
        assert row.push_registration_id is None
        assert row.push_platform == "ios"

    def test_unregister_revoked_session_stays_401_without_mutating_push_fields(self, client):
        first_resp = client.post("/push/test-session")
        first_id = first_resp.json()["sessionId"]
        first_session = client.app.state.sessions.get(first_id)
        first_session.student_account = "20240001"

        register_resp = client.post(
            "/push/register",
            json={"registrationId": "old-device", "platform": "android"},
            headers={"X-Session-Id": first_id},
        )
        assert register_resp.status_code == 200

        second_resp = client.post("/push/test-session")
        second_id = second_resp.json()["sessionId"]
        second_session = client.app.state.sessions.get(second_id)
        second_session.student_account = "20240001"
        client.app.state.sessions.update(first_id, student_name="测试用户")

        factory = get_sync_session_factory()
        with factory() as db:
            first_row = db.query(AppSessionModel).filter(AppSessionModel.id == first_id).first()
            second_row = db.query(AppSessionModel).filter(AppSessionModel.id == second_id).first()
            assert first_row is not None
            assert second_row is not None
            first_row.student_account = "20240001"
            second_row.student_account = "20240001"
            first_row.revoked_at = first_row.created_at
            first_row.revoked_reason = "single_device_login"
            db.commit()

        unregister_resp = client.post(
            "/push/unregister",
            json={},
            headers={"X-Session-Id": first_id},
        )
        assert unregister_resp.status_code == 401

        row = _get_session_row(first_id)
        assert row.push_registration_id == "old-device"
        assert row.push_platform == "android"
        assert _count_push_registration("old-device") == 1


class TestPushSchemas:
    def test_register_missing_registration_id(self, client):
        resp = client.post(
            "/push/register",
            json={},
            headers={"X-Session-Id": "fake"},
        )
        assert resp.status_code == 401
