import base64
import io
import json
import zipfile

import pytest
from fastapi.testclient import TestClient

from app.database import (
    AdminAuditLog,
    AdminNotice,
    LoginCarouselSlide,
    WxArticle,
    get_sync_session_factory,
)
from app.main import app
from app.sessions import AppSession
from app.shiply_content import (
    DownloadedImage,
    ShiplyContentExportError,
    build_public_content_bundle,
)


class _FakeSchoolClient:
    def __init__(self, student_id: str = "20240001"):
        self._student_id = student_id

    def get_info(self):
        return {"studentId": self._student_id, "name": "测试用户"}

    def get_notices(self):
        return [{"category": "通知公告", "title": "测试通知", "date": "2026-09-17"}]

    def logout(self):
        pass


def _authed_session(monkeypatch):
    session = AppSession(
        id="shiply-export-session",
        client=_FakeSchoolClient(),
        student_name="测试用户",
        is_admin=True,
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    return {"X-Session-Id": session.id}


def _seed_public_content() -> None:
    factory = get_sync_session_factory()
    with factory() as db:
        db.add_all(
            [
                AdminNotice(title="未发布", published=False, is_pinned=True),
                AdminNotice(
                    title="普通校历",
                    description="普通内容",
                    image_data=base64.b64encode(b"notice").decode(),
                    image_mime="image/png",
                    published=True,
                    is_pinned=False,
                ),
                AdminNotice(title="置顶校历", published=True, is_pinned=True),
                LoginCarouselSlide(
                    title="未发布轮播",
                    image_data=base64.b64encode(b"hidden-slide").decode(),
                    image_mime="image/png",
                    published=False,
                    sort_order=0,
                ),
                LoginCarouselSlide(
                    title="已发布轮播",
                    image_data=base64.b64encode(b"slide").decode(),
                    image_mime="image/png",
                    published=True,
                    sort_order=1,
                ),
                WxArticle(
                    title="可见文章",
                    summary="摘要",
                    cover_url="https://img.example.test/cover.jpg",
                    article_url="https://mp.weixin.qq.com/s/visible",
                    publish_time="2026-09-17",
                    hidden=False,
                ),
                WxArticle(
                    title="隐藏文章",
                    cover_url=None,
                    article_url="https://mp.weixin.qq.com/s/hidden",
                    hidden=True,
                ),
            ]
        )
        db.commit()


def test_public_content_bundle_filters_orders_and_persists_media(monkeypatch):
    _seed_public_content()

    def fake_download(url: str) -> DownloadedImage:
        assert url == "https://img.example.test/cover.jpg"
        return DownloadedImage(data=b"cover", mime="image/jpeg")

    monkeypatch.setattr("app.shiply_content.download_cover_image", fake_download)
    bundle = build_public_content_bundle()

    with zipfile.ZipFile(io.BytesIO(bundle.archive)) as archive:
        names = set(archive.namelist())
        assert names == {
            "manifest.json",
            "notices.json",
            "login_slides.json",
            "wechat_articles.json",
            "media/notices/2.png",
            "media/wechat/1.jpg",
            "media/login-slides/2.png",
        }
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["resourceKey"] == "gzus_public_content"
        assert manifest["counts"] == {
            "notices": 2,
            "loginSlides": 1,
            "wechatArticles": 1,
            "media": 3,
        }
        assert [item["title"] for item in json.loads(archive.read("notices.json"))] == [
            "置顶校历",
            "普通校历",
        ]
        assert json.loads(archive.read("wechat_articles.json"))[0]["coverPath"] == (
            "media/wechat/1.jpg"
        )
        assert archive.read("media/wechat/1.jpg") == b"cover"


def test_public_content_bundle_cover_download_failure_is_explicit(monkeypatch):
    _seed_public_content()

    def fail_download(url: str) -> DownloadedImage:
        raise ShiplyContentExportError(f"封面下载失败: {url}")

    monkeypatch.setattr("app.shiply_content.download_cover_image", fail_download)
    with pytest.raises(ShiplyContentExportError, match="封面下载失败"):
        build_public_content_bundle()


def test_shiply_export_endpoint_returns_zip_headers_and_audit(monkeypatch):
    headers = _authed_session(monkeypatch)
    _seed_public_content()
    monkeypatch.setattr(
        "app.shiply_content.download_cover_image",
        lambda url: DownloadedImage(data=b"cover", mime="image/jpeg"),
    )

    with TestClient(app) as client:
        response = client.post("/admin/shiply/public-content/export", headers=headers)

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/zip"
    assert response.headers["x-shiply-content-sha256"]
    assert json.loads(response.headers["x-shiply-content-counts"])["notices"] == 2
    with get_sync_session_factory()() as db:
        audit = (
            db.query(AdminAuditLog)
            .filter(AdminAuditLog.action == "export_shiply_public_content")
            .one()
        )
        assert audit.target_id == "gzus_public_content"


def test_notices_include_public_false_only_returns_student_items(monkeypatch):
    session = AppSession(
        id="personal-notice-session",
        client=_FakeSchoolClient(),
        student_name="测试用户",
    )
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    _seed_public_content()

    with TestClient(app) as client:
        response = client.get(
            "/notices?includePublic=false",
            headers={"X-Session-Id": session.id},
        )

    assert response.status_code == 200
    assert [item["title"] for item in response.json()] == ["测试通知"]
