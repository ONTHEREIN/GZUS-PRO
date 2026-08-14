from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.database import AppSessionModel, get_sync_session_factory
from app.main import app
from app.sessions import SessionStore


@pytest.fixture
def client():
    app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
    return TestClient(app)


def _reset_session_store(client: TestClient) -> None:
    client.app.state.sessions = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)


def test_notifications_websocket_recovers_session_after_cold_start(client):
    session_resp = client.post("/push/test-session")
    session_id = session_resp.json()["sessionId"]
    _reset_session_store(client)

    with client.websocket_connect(f"/ws/notifications?sessionId={session_id}"):
        pass


def test_notifications_websocket_rejects_revoked_session_after_cold_start(client):
    session_resp = client.post("/push/test-session")
    session_id = session_resp.json()["sessionId"]

    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
        assert row is not None
        row.revoked_at = datetime.now(timezone.utc)
        row.revoked_reason = "single_device_login"
        db.commit()

    _reset_session_store(client)

    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect(f"/ws/notifications?sessionId={session_id}"):
            pass
    assert exc.value.code == 4001
