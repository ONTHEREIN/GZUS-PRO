from fastapi.testclient import TestClient

from app.main import app
from app.sessions import AppSession


class FakeSchoolClient:
    def __init__(self, student_id: str) -> None:
        self._student_id = student_id

    def get_info(self) -> dict[str, str]:
        return {"studentId": self._student_id, "name": "测试用户"}

    def logout(self) -> None:
        return None


def _authed_session(monkeypatch, session_id: str = "schedule-session") -> AppSession:
    session = AppSession(
        id=session_id,
        client=FakeSchoolClient("20240001"),
        student_name="测试用户",
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return session


def _payload() -> dict[str, object]:
    return {
        "clientId": "adjustment-test-1",
        "year": 2026,
        "term": 1,
        "sourceDate": "2026-09-07",
        "targetDate": "2026-09-12",
        "sourceOccurrenceKeys": ["course:2026-09-07:math"],
        "targetConflictKeys": ["course:2026-09-12:physics"],
        "conflictMode": "replaceConflicts",
    }


def test_schedule_adjustment_is_idempotent_and_keeps_history(monkeypatch):
    session = _authed_session(monkeypatch)
    headers = {"X-Session-Id": session.id}
    with TestClient(app) as client:
        first = client.post("/settings/schedule/adjustments", headers=headers, json=_payload())
        duplicate = client.post("/settings/schedule/adjustments", headers=headers, json=_payload())
        listed = client.get(
            "/settings/schedule/adjustments?year=2026&term=1", headers=headers
        )

    assert first.status_code == 201
    assert duplicate.status_code == 201
    assert duplicate.json()["id"] == first.json()["id"]
    assert len(listed.json()) == 1
    assert listed.json()[0]["status"] == "active"


def test_schedule_adjustment_revision_conflict_and_restore(monkeypatch):
    session = _authed_session(monkeypatch)
    headers = {"X-Session-Id": session.id}
    with TestClient(app) as client:
        created = client.post("/settings/schedule/adjustments", headers=headers, json=_payload())
        updated = client.patch(
            "/settings/schedule/adjustments/adjustment-test-1",
            headers=headers,
            json={"expectedRevision": 1, "conflictMode": "coexist"},
        )
        conflict = client.patch(
            "/settings/schedule/adjustments/adjustment-test-1",
            headers=headers,
            json={"expectedRevision": 1, "conflictMode": "replaceConflicts"},
        )
        restored = client.post(
            "/settings/schedule/adjustments/adjustment-test-1/restore?expectedRevision=2",
            headers=headers,
            json={},
        )

    assert created.status_code == 201
    assert updated.status_code == 200
    assert updated.json()["revision"] == 2
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["server"]["revision"] == 2
    assert restored.status_code == 200
    assert restored.json()["status"] == "restored"
    assert restored.json()["revision"] == 3


def test_schedule_adjustment_rejects_impossible_date(monkeypatch):
    session = _authed_session(monkeypatch)
    payload = _payload()
    payload["sourceDate"] = "2026-02-30"
    with TestClient(app) as client:
        response = client.post(
            "/settings/schedule/adjustments",
            headers={"X-Session-Id": session.id},
            json=payload,
        )

    assert response.status_code == 422
