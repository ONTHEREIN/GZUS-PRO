import pytest
from fastapi.testclient import TestClient

from app.database import get_sync_session_factory
from app.main import app
from app.sessions import SessionStore


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
