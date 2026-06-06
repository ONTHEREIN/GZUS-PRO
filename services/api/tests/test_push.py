import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture
def client():
    return TestClient(app)


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


class TestPushSchemas:
    def test_register_missing_registration_id(self, client):
        resp = client.post(
            "/push/register",
            json={},
            headers={"X-Session-Id": "fake"},
        )
        assert resp.status_code == 401
