import base64
import io
import json
import time
import zipfile
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.database import (
    AdminAuditLog,
    AdminNotice,
    LoginCarouselSlide,
    ShiplyExportJob,
    WxArticle,
    get_sync_session_factory,
)
from app.main import app
from app.sessions import AppSession
from app.shiply_content import (
    SHIPLY_HOME_RESOURCE_KIND,
    SHIPLY_LOGIN_RESOURCE_KIND,
    DownloadedImage,
    ShiplyContentExportError,
    build_home_content_bundle,
    build_login_content_bundle,
)
from app.shiply_export_jobs import reconcile_shiply_export_jobs
from app.shiply_export_jobs import create_or_get_shiply_export_job


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


def test_login_bundle_only_contains_published_slides(monkeypatch):
    _seed_public_content()
    monkeypatch.setattr(
        "app.shiply_content.download_cover_image",
        lambda url: (_ for _ in ()).throw(AssertionError(f"登录包不应下载封面: {url}")),
    )

    bundle = build_login_content_bundle()

    with zipfile.ZipFile(io.BytesIO(bundle.archive)) as archive:
        assert set(archive.namelist()) == {
            "manifest.json",
            "login_slides.json",
            "media/login-slides/2.png",
        }
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["resourceKey"] == "gzus_login_content"
        assert manifest["resourceKind"] == SHIPLY_LOGIN_RESOURCE_KIND
        assert manifest["files"] == {"loginSlides": "login_slides.json"}
        assert [item["title"] for item in json.loads(archive.read("login_slides.json"))] == [
            "已发布轮播"
        ]


def test_home_bundle_filters_orders_and_persists_media(monkeypatch):
    _seed_public_content()

    def fake_download(url: str) -> DownloadedImage:
        assert url == "https://img.example.test/cover.jpg"
        return DownloadedImage(data=b"cover", mime="image/jpeg")

    monkeypatch.setattr("app.shiply_content.download_cover_image", fake_download)
    bundle = build_home_content_bundle()

    with zipfile.ZipFile(io.BytesIO(bundle.archive)) as archive:
        assert set(archive.namelist()) == {
            "manifest.json",
            "notices.json",
            "wechat_articles.json",
            "media/notices/2.png",
            "media/wechat/1.jpg",
        }
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["resourceKey"] == "gzus_public_content"
        assert manifest["resourceKind"] == SHIPLY_HOME_RESOURCE_KIND
        assert manifest["counts"] == {"notices": 2, "wechatArticles": 1, "media": 2}
        assert [item["title"] for item in json.loads(archive.read("notices.json"))] == [
            "置顶校历",
            "普通校历",
        ]
        assert archive.read("media/wechat/1.jpg") == b"cover"


def test_home_bundle_cover_download_failure_is_explicit(monkeypatch):
    _seed_public_content()
    monkeypatch.setattr(
        "app.shiply_content.download_cover_image",
        lambda url: (_ for _ in ()).throw(ShiplyContentExportError(f"封面下载失败: {url}")),
    )

    with pytest.raises(ShiplyContentExportError, match="封面下载失败"):
        build_home_content_bundle()


def _wait_for_job(client: TestClient, headers: dict[str, str], job_id: str) -> dict:
    for _ in range(100):
        response = client.get(f"/admin/shiply/exports/{job_id}", headers=headers)
        assert response.status_code == 200
        body = response.json()
        if body["status"] not in {"queued", "running"}:
            return body
        time.sleep(0.01)
    raise AssertionError("Shiply 导出任务未在测试时限内结束")


def test_shiply_export_creation_deduplicates_active_job(monkeypatch):
    headers = _authed_session(monkeypatch)
    with TestClient(app) as client:
        initial, created = create_or_get_shiply_export_job("home", "20240001")
        assert created is True
        created = client.post("/admin/shiply/exports", headers=headers, json={"resource": "home"})
        duplicate = client.post("/admin/shiply/exports", headers=headers, json={"resource": "home"})

    assert created.status_code == 202
    assert duplicate.status_code == 202
    assert created.json()["id"] == initial.id
    assert duplicate.json()["id"] == initial.id


def test_shiply_export_job_succeeds_and_downloads(monkeypatch):
    headers = _authed_session(monkeypatch)
    _seed_public_content()
    monkeypatch.setattr(
        "app.shiply_content.download_cover_image",
        lambda url: DownloadedImage(data=b"cover", mime="image/jpeg"),
    )

    with TestClient(app) as client:
        created = client.post("/admin/shiply/exports", headers=headers, json={"resource": "home"})
        assert created.status_code == 202
        finished = _wait_for_job(client, headers, created.json()["id"])
        assert finished["status"] == "succeeded"
        assert finished["resourceKey"] == "gzus_public_content"
        download = client.get(f"/admin/shiply/exports/{finished['id']}/download", headers=headers)

    assert download.status_code == 200
    assert download.headers["content-type"] == "application/zip"
    assert download.headers["x-shiply-resource-key"] == "gzus_public_content"
    with get_sync_session_factory()() as db:
        actions = {row.action for row in db.query(AdminAuditLog).all()}
        assert "request_shiply_resource_export" in actions
        assert "export_shiply_resource" in actions


def test_shiply_export_job_failure_and_expired_job_cleanup(monkeypatch):
    headers = _authed_session(monkeypatch)
    monkeypatch.setattr(
        "app.shiply_export_jobs.build_content_bundle",
        lambda resource: (_ for _ in ()).throw(ShiplyContentExportError("封面不可用")),
    )

    with TestClient(app) as client:
        created = client.post("/admin/shiply/exports", headers=headers, json={"resource": "home"})
        finished = _wait_for_job(client, headers, created.json()["id"])
        assert finished["status"] == "failed"
        assert finished["error"] == "封面不可用"
        download = client.get(f"/admin/shiply/exports/{finished['id']}/download", headers=headers)
        assert download.status_code == 409

    factory = get_sync_session_factory()
    with factory() as db:
        db.add_all(
            [
                ShiplyExportJob(
                    id="expired-shiply-job",
                    resource_kind="login",
                    resource_key="gzus_login_content",
                    operator_id="20240001",
                    status="succeeded",
                    expires_at=datetime.now(UTC) - timedelta(seconds=1),
                ),
                ShiplyExportJob(
                    id="restarted-shiply-job",
                    resource_kind="login",
                    resource_key="gzus_login_content",
                    operator_id="20240001",
                    status="running",
                    expires_at=datetime.now(UTC) + timedelta(hours=1),
                ),
            ]
        )
        db.commit()
    reconcile_shiply_export_jobs()
    with factory() as db:
        assert db.get(ShiplyExportJob, "expired-shiply-job") is None
        restarted = db.get(ShiplyExportJob, "restarted-shiply-job")
        assert restarted is not None
        assert restarted.status == "failed"
        assert restarted.error == "服务器在资源包生成期间重启，请重新生成"


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
