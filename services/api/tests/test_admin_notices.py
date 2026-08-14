"""管理后台新增功能测试：校历上传（CRUD/图片端点）与公众号文章管理。"""
import base64

from fastapi.testclient import TestClient

from app.database import AdminNotice, WxArticle, get_sync_session_factory
from app.main import app
from app.routes import admin as admin_route
from app.sessions import AppSession
from app.wechat_service import WechatArticle, upsert_articles


class FakeSchoolClient:
    def __init__(self, student_id="20240001"):
        self._student_id = student_id

    def get_info(self):
        return {"studentId": self._student_id, "name": "测试用户"}

    def logout(self):
        pass


def _authed_session(
    monkeypatch,
    session_id="test-session",
    student_id="20240001",
    is_admin=True,
):
    session = AppSession(
        id=session_id,
        client=FakeSchoolClient(student_id),
        student_name="测试用户",
        is_admin=is_admin,
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return session


def _auth_header(session_id="test-session"):
    return {"X-Session-Id": session_id}


# ─── 校历/通知 CRUD ─────────────────────────────────────

def test_notices_require_admin(monkeypatch):
    _authed_session(monkeypatch, is_admin=False)
    with TestClient(app) as client:
        assert client.get("/admin/notices", headers=_auth_header()).status_code == 403


def test_notices_create_and_list(monkeypatch):
    _authed_session(monkeypatch)
    png_b64 = base64.b64encode(b"\x89PNG\r\n\x1a\nfake-image-bytes").decode()
    with TestClient(app) as client:
        resp = client.post(
            "/admin/notices",
            json={
                "title": "2026-2027学年校历",
                "description": "第一学期 9 月 1 日开学",
                "imageData": png_b64,
                "imageMime": "image/png",
                "isPinned": True,
            },
            headers=_auth_header(),
        )
        assert resp.status_code == 201
        data = resp.json()
        assert data["title"] == "2026-2027学年校历"
        assert data["coverUrl"] == "/admin/notices/1/image"
        assert data["isPinned"] is True
        notice_id = data["id"]

        items = client.get("/admin/notices", headers=_auth_header()).json()
        assert items["total"] == 1
        assert items["items"][0]["id"] == notice_id

        # 图片端点公开可读
        img = client.get(f"/admin/notices/{notice_id}/image")
        assert img.status_code == 200
        assert img.content == b"\x89PNG\r\n\x1a\nfake-image-bytes"
        assert img.headers["content-type"] == "image/png"


def test_notice_create_with_data_url_prefix(monkeypatch):
    _authed_session(monkeypatch)
    png_b64 = base64.b64encode(b"fake").decode()
    with TestClient(app) as client:
        resp = client.post(
            "/admin/notices",
            json={
                "title": "带 data URL 前缀",
                "imageData": f"data:image/jpeg;base64,{png_b64}",
            },
            headers=_auth_header(),
        )
        assert resp.status_code == 201
        assert resp.json()["imageMime"] == "image/jpeg"


def test_notice_image_too_large_rejected(monkeypatch):
    _authed_session(monkeypatch)
    big = base64.b64encode(b"x" * (3 * 1024 * 1024 + 1)).decode()
    with TestClient(app) as client:
        resp = client.post(
            "/admin/notices",
            json={"title": "超大图", "imageData": big},
            headers=_auth_header(),
        )
        assert resp.status_code == 413


def test_notice_update_and_delete(monkeypatch):
    _authed_session(monkeypatch)
    with TestClient(app) as client:
        created = client.post(
            "/admin/notices",
            json={"title": "旧标题", "published": True},
            headers=_auth_header(),
        ).json()
        notice_id = created["id"]

        updated = client.put(
            f"/admin/notices/{notice_id}",
            json={"title": "新标题", "published": False, "isPinned": True},
            headers=_auth_header(),
        ).json()
        assert updated["title"] == "新标题"
        assert updated["published"] is False
        assert updated["isPinned"] is True

        resp = client.delete(f"/admin/notices/{notice_id}", headers=_auth_header())
        assert resp.status_code == 200
        assert client.get("/admin/notices", headers=_auth_header()).json()["total"] == 0
        assert client.get(f"/admin/notices/{notice_id}/image").status_code == 404


def test_list_published_admin_notices_only_published():
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(AdminNotice(title="已发布", published=True, is_pinned=False))
        db.add(AdminNotice(title="未发布", published=False, is_pinned=False))
        db.commit()
    items = admin_route.list_published_admin_notices()
    assert [i["title"] for i in items] == ["已发布"]
    assert items[0]["category"] == "校历"


# ─── 公众号文章管理 ─────────────────────────────────────

def _seed_articles():
    upsert_articles(
        [
            WechatArticle(title="文章一", summary="摘要一", cover_url="c1", article_url="u1"),
            WechatArticle(title="文章二", summary=None, cover_url=None, article_url="u2"),
        ]
    )


def test_wechat_articles_list(monkeypatch):
    _authed_session(monkeypatch)
    _seed_articles()
    with TestClient(app) as client:
        data = client.get("/admin/wechat/articles", headers=_auth_header()).json()
        assert data["total"] == 2
        assert {i["title"] for i in data["items"]} == {"文章一", "文章二"}
        assert data["items"][0]["source"] == "album"


def test_wechat_article_hide_unhide_delete(monkeypatch):
    _authed_session(monkeypatch)
    _seed_articles()
    factory = get_sync_session_factory()
    with factory() as db:
        article_id = db.query(WxArticle).filter(WxArticle.article_url == "u1").first().id

    with TestClient(app) as client:
        assert client.post(f"/admin/wechat/articles/{article_id}/hide", headers=_auth_header()).status_code == 200
        data = client.get("/admin/wechat/articles", headers=_auth_header()).json()
        assert next(i for i in data["items"] if i["id"] == article_id)["hidden"] is True

        assert client.post(f"/admin/wechat/articles/{article_id}/unhide", headers=_auth_header()).status_code == 200
        data = client.get("/admin/wechat/articles", headers=_auth_header()).json()
        assert next(i for i in data["items"] if i["id"] == article_id)["hidden"] is False

        assert client.delete(f"/admin/wechat/articles/{article_id}", headers=_auth_header()).status_code == 200
        assert client.delete(f"/admin/wechat/articles/{article_id}", headers=_auth_header()).status_code == 404


def test_wechat_import_by_url(monkeypatch):
    _authed_session(monkeypatch)

    class FakeResp:
        text = '<meta property="og:title" content="导入标题">'
        raise_for_status = lambda self: None

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        def get(self, url):
            return FakeResp()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    import app.wechat_service as ws

    monkeypatch.setattr(ws.httpx, "Client", FakeClient)
    with TestClient(app) as client:
        resp = client.post(
            "/admin/wechat/import",
            json={"url": "https://mp.weixin.qq.com/s/import-test"},
            headers=_auth_header(),
        )
        assert resp.status_code == 200
        assert resp.json()["title"] == "导入标题"
        assert resp.json()["added"] == 1


def test_wechat_sync_now(monkeypatch):
    _authed_session(monkeypatch)

    class FakeFetcher:
        def fetch_latest(self, limit=50):
            return [WechatArticle(title="同步标题", summary=None, cover_url=None, article_url="sync-u1")]

    monkeypatch.setattr("app.wechat_service.AlbumFetcher", lambda *a, **k: FakeFetcher())
    with TestClient(app) as client:
        resp = client.post("/admin/wechat/sync", headers=_auth_header())
        assert resp.status_code == 200
        assert resp.json()["added"] == 1
