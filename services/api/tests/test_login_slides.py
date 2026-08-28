"""登录页轮播内容的公开读取与管理员维护测试。"""
import base64

from fastapi.testclient import TestClient

from app.database import AdminAuditLog, LoginCarouselSlide, get_sync_session_factory
from app.main import app
from app.sessions import AppSession


class FakeSchoolClient:
    def get_info(self):
        return {"studentId": "20240001", "name": "测试管理员"}

    def logout(self):
        pass


def _admin_session(monkeypatch, is_admin=True):
    session = AppSession(
        id="login-slide-session",
        client=FakeSchoolClient(),
        student_name="测试管理员",
        is_admin=is_admin,
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return {"X-Session-Id": "login-slide-session"}


def _slide_payload(title, published=True):
    image_data = base64.b64encode(f"image-{title}".encode()).decode()
    return {
        "title": title,
        "description": f"{title} 的介绍",
        "imageData": image_data,
        "imageMime": "image/png",
        "published": published,
    }


def test_login_slides_require_admin(monkeypatch):
    headers = _admin_session(monkeypatch, is_admin=False)
    with TestClient(app) as client:
        response = client.get("/admin/login-slides", headers=headers)
    assert response.status_code == 403


def test_login_slides_public_list_image_and_audit(monkeypatch):
    headers = _admin_session(monkeypatch)
    with TestClient(app) as client:
        created = client.post(
            "/admin/login-slides",
            json=_slide_payload("欢迎使用"),
            headers=headers,
        )
        assert created.status_code == 201
        slide = created.json()

        public_items = client.get("/content/login-slides")
        assert public_items.status_code == 200
        assert public_items.json() == [
            {
                "id": slide["id"],
                "title": "欢迎使用",
                "description": "欢迎使用 的介绍",
                "imageUrl": f"/content/login-slides/{slide['id']}/image",
            }
        ]

        image = client.get(f"/content/login-slides/{slide['id']}/image")
        assert image.status_code == 200
        assert image.content == b"image-\xe6\xac\xa2\xe8\xbf\x8e\xe4\xbd\xbf\xe7\x94\xa8"
        assert image.headers["content-type"] == "image/png"

    factory = get_sync_session_factory()
    with factory() as db:
        audit = db.query(AdminAuditLog).filter(AdminAuditLog.action == "create_login_slide").one()
        assert audit.target_id == str(slide["id"])


def test_unpublished_slides_are_hidden_and_can_be_updated(monkeypatch):
    headers = _admin_session(monkeypatch)
    with TestClient(app) as client:
        created = client.post(
            "/admin/login-slides",
            json=_slide_payload("草稿", published=False),
            headers=headers,
        ).json()
        slide_id = created["id"]

        assert client.get("/content/login-slides").json() == []
        assert client.get(f"/content/login-slides/{slide_id}/image").status_code == 404

        updated = client.put(
            f"/admin/login-slides/{slide_id}",
            json={"description": None, "published": True},
            headers=headers,
        )
        assert updated.status_code == 200
        assert updated.json()["description"] is None
        assert client.get("/content/login-slides").json()[0]["title"] == "草稿"


def test_login_slide_reorder_and_published_limit(monkeypatch):
    headers = _admin_session(monkeypatch)
    with TestClient(app) as client:
        slides = [
            client.post("/admin/login-slides", json=_slide_payload(f"轮播 {index}"), headers=headers).json()
            for index in range(1, 6)
        ]
        rejected = client.post(
            "/admin/login-slides",
            json=_slide_payload("第六张"),
            headers=headers,
        )
        assert rejected.status_code == 400

        ordered_ids = [slide["id"] for slide in reversed(slides)]
        reordered = client.put(
            "/admin/login-slides/actions/order",
            json={"ids": ordered_ids},
            headers=headers,
        )
        assert reordered.status_code == 200
        assert [item["id"] for item in reordered.json()["items"]] == ordered_ids
        assert [item["id"] for item in client.get("/content/login-slides").json()] == ordered_ids

        deleted = client.delete(f"/admin/login-slides/{ordered_ids[0]}", headers=headers)
        assert deleted.status_code == 200

    factory = get_sync_session_factory()
    with factory() as db:
        assert db.query(LoginCarouselSlide).count() == 4
        assert db.query(AdminAuditLog).filter(AdminAuditLog.action == "reorder_login_slides").count() == 1


def test_login_slide_image_over_limit_is_rejected(monkeypatch):
    headers = _admin_session(monkeypatch)
    image_data = base64.b64encode(b"x" * (3 * 1024 * 1024 + 1)).decode()
    with TestClient(app) as client:
        response = client.post(
            "/admin/login-slides",
            json={
                "title": "超大图片",
                "imageData": image_data,
                "imageMime": "image/png",
                "published": False,
            },
            headers=headers,
        )
    assert response.status_code == 413
