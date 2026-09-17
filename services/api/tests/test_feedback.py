import base64

from fastapi.testclient import TestClient

from app.database import AdminUser, FeedbackTicket, get_sync_session_factory
from app.main import app
from app.sessions import AppSession


class FakeSchoolClient:
    def __init__(self, student_id: str):
        self.student_id = student_id

    def get_info(self):
        return {"studentId": self.student_id, "name": "反馈用户"}


def _authed_session(monkeypatch, student_id: str, is_admin: bool) -> None:
    session = AppSession(
        id="feedback-session",
        client=FakeSchoolClient(student_id),
        student_name="反馈用户",
        student_account=student_id,
        is_admin=is_admin,
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)


def _add_admin(student_id: str) -> None:
    with get_sync_session_factory()() as db:
        db.add(AdminUser(student_id=student_id, role="admin"))
        db.commit()


def test_feedback_requires_login():
    with TestClient(app) as client:
        response = client.post(
            "/feedback",
            json={"category": "bug", "title": "标题", "description": "描述"},
        )
    assert response.status_code == 401


def test_user_can_submit_feedback_with_attachment(monkeypatch):
    _authed_session(monkeypatch, "20240001", is_admin=False)
    attachment = base64.b64encode(b"screenshot").decode("ascii")
    with TestClient(app) as client:
        response = client.post(
            "/feedback",
            headers={"X-Session-Id": "feedback-session"},
            json={
                "category": "bug",
                "title": "课表加载失败",
                "description": "打开课表后显示空白。",
                "contact": "test@example.com",
                "clientLogs": "最近日志",
                "attachments": [
                    {
                        "name": "screen.png",
                        "mimeType": "image/png",
                        "contentBase64": attachment,
                    }
                ],
            },
        )
    assert response.status_code == 201
    assert response.json()["status"] == "open"

    with get_sync_session_factory()() as db:
        row = db.query(FeedbackTicket).one()
        assert row.student_id == "20240001"
        assert row.client_logs == "最近日志"
        assert '"name":"screen.png"' in row.attachments_json


def test_admin_can_list_and_view_feedback_details(monkeypatch):
    _authed_session(monkeypatch, "20240001", is_admin=False)
    with TestClient(app) as client:
        client.post(
            "/feedback",
            headers={"X-Session-Id": "feedback-session"},
            json={
                "category": "suggestion",
                "title": "增加快捷入口",
                "description": "希望更多页可以快速提交建议。",
                "clientLogs": "诊断日志",
            },
        )

    _authed_session(monkeypatch, "20240002", is_admin=True)
    _add_admin("20240002")
    with TestClient(app) as client:
        listing = client.get(
            "/admin/feedback",
            headers={"X-Session-Id": "feedback-session"},
        )
        detail = client.get(
            "/admin/feedback/1",
            headers={"X-Session-Id": "feedback-session"},
        )
    assert listing.status_code == 200
    assert listing.json()["total"] == 1
    assert listing.json()["items"][0]["category"] == "suggestion"
    assert detail.status_code == 200
    assert detail.json()["clientLogs"] == "诊断日志"


def test_non_admin_cannot_view_feedback(monkeypatch):
    _authed_session(monkeypatch, "20240001", is_admin=False)
    with TestClient(app) as client:
        response = client.get(
            "/admin/feedback",
            headers={"X-Session-Id": "feedback-session"},
        )
    assert response.status_code == 403


def test_feedback_rejects_invalid_attachment(monkeypatch):
    _authed_session(monkeypatch, "20240001", is_admin=False)
    with TestClient(app) as client:
        response = client.post(
            "/feedback",
            headers={"X-Session-Id": "feedback-session"},
            json={
                "category": "bug",
                "title": "无效附件",
                "description": "测试",
                "attachments": [
                    {"name": "bad.txt", "contentBase64": "not-base64"},
                ],
            },
        )
    assert response.status_code == 400
