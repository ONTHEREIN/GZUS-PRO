"""构建 Shiply 登录页与登录后首页的独立资源包。"""

from __future__ import annotations

import base64
import binascii
import hashlib
import io
import json
import logging
import mimetypes
import posixpath
import re
import zipfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import urlparse

import httpx

from app.database import AdminNotice, LoginCarouselSlide, WxArticle, get_sync_session_factory

logger = logging.getLogger(__name__)

SHIPLY_LOGIN_CONTENT_KEY = "gzus_login_content"
SHIPLY_PUBLIC_CONTENT_KEY = "gzus_public_content"
SHIPLY_LOGIN_RESOURCE_KIND = "login"
SHIPLY_HOME_RESOURCE_KIND = "home"
SHIPLY_SCHEMA_VERSION = 1
MAX_IMAGE_BYTES = 3 * 1024 * 1024
DOWNLOAD_TIMEOUT = httpx.Timeout(20.0, connect=5.0)
DOWNLOAD_RETRIES = 3
MAX_PARALLEL_COVER_DOWNLOADS = 4


class ShiplyContentExportError(RuntimeError):
    """公共资源包无法构建时的可操作错误。"""


@dataclass(frozen=True)
class DownloadedImage:
    data: bytes
    mime: str


@dataclass(frozen=True)
class ShiplyContentBundle:
    archive: bytes
    filename: str
    generated_at: str
    resource_key: str
    sha256: str
    counts: dict[str, int]


def resource_key_for_kind(resource_kind: str) -> str:
    if resource_kind == SHIPLY_LOGIN_RESOURCE_KIND:
        return SHIPLY_LOGIN_CONTENT_KEY
    if resource_kind == SHIPLY_HOME_RESOURCE_KIND:
        return SHIPLY_PUBLIC_CONTENT_KEY
    raise ShiplyContentExportError(f"不支持的 Shiply 资源类型: {resource_kind}")


def build_content_bundle(resource_kind: str) -> ShiplyContentBundle:
    if resource_kind == SHIPLY_LOGIN_RESOURCE_KIND:
        return build_login_content_bundle()
    if resource_kind == SHIPLY_HOME_RESOURCE_KIND:
        return build_home_content_bundle()
    raise ShiplyContentExportError(f"不支持的 Shiply 资源类型: {resource_kind}")


def _json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _extension_for_mime(mime: str | None) -> str:
    normalized = (mime or "").split(";", 1)[0].strip().lower()
    extensions = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
        "image/bmp": ".bmp",
        "image/heic": ".heic",
        "image/heif": ".heif",
    }
    if normalized in extensions:
        return extensions[normalized]
    guessed = mimetypes.guess_extension(normalized)
    if guessed and re.fullmatch(r"\.[a-z0-9]{1,8}", guessed.lower()):
        return guessed.lower()
    return ".bin"


def _safe_asset_name(prefix: str, row_id: int, mime: str | None) -> str:
    return f"media/{prefix}/{row_id}{_extension_for_mime(mime)}"


def _decode_image(encoded: str, label: str) -> bytes:
    normalized = encoded
    if normalized.startswith("data:"):
        _, separator, normalized = normalized.partition(",")
        if not separator:
            raise ShiplyContentExportError(f"{label} 图片 data URL 缺少内容")
    try:
        data = base64.b64decode(normalized, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ShiplyContentExportError(f"{label} 图片 base64 解码失败") from exc
    if not data:
        raise ShiplyContentExportError(f"{label} 图片内容为空")
    if len(data) > MAX_IMAGE_BYTES:
        raise ShiplyContentExportError(f"{label} 图片超过 3MB 限制")
    return data


def _cover_file_name(article_id: int, mime: str | None) -> str:
    return _safe_asset_name("wechat", article_id, mime or "image/jpeg")


def download_cover_image(url: str) -> DownloadedImage:
    """下载公众号封面；失败重试后抛出明确错误，不生成不完整资源包。"""
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ShiplyContentExportError(f"公众号封面 URL 无效: {url}")
    last_error: Exception | None = None
    for attempt in range(1, DOWNLOAD_RETRIES + 1):
        try:
            with httpx.Client(timeout=DOWNLOAD_TIMEOUT, follow_redirects=True) as client:
                response = client.get(url)
                response.raise_for_status()
            content_type = response.headers.get("content-type", "").split(";", 1)[0].strip()
            if not content_type.startswith("image/"):
                raise ShiplyContentExportError(
                    f"公众号封面返回了非图片内容: url={url}, contentType={content_type or 'unknown'}"
                )
            if not response.content:
                raise ShiplyContentExportError(f"公众号封面内容为空: {url}")
            if len(response.content) > MAX_IMAGE_BYTES:
                raise ShiplyContentExportError(f"公众号封面超过 3MB 限制: {url}")
            return DownloadedImage(data=response.content, mime=content_type)
        except ShiplyContentExportError:
            raise
        except (httpx.HTTPError, OSError) as exc:
            last_error = exc
            logger.warning(
                "shiply_cover_download_failed",
                extra={"url": url, "attempt": attempt, "max_attempts": DOWNLOAD_RETRIES},
            )
    raise ShiplyContentExportError(
        f"公众号封面下载失败，已重试 {DOWNLOAD_RETRIES} 次: {url}: {last_error}"
    )


def _public_notice_payload(row: AdminNotice, media: dict[str, bytes]) -> dict[str, object]:
    cover_path: str | None = None
    if row.image_data:
        cover_path = _safe_asset_name("notices", row.id, row.image_mime)
        media[cover_path] = _decode_image(row.image_data, f"管理员通知 #{row.id}")
    return {
        "id": row.id,
        "category": "校历",
        "title": row.title,
        "description": row.description,
        "date": row.created_at.strftime("%Y-%m-%d") if row.created_at else None,
        "url": None,
        "summary": row.description,
        "coverPath": cover_path,
        "source": "admin",
        "isPinned": bool(row.is_pinned),
    }


def _login_slide_payload(row: LoginCarouselSlide, media: dict[str, bytes]) -> dict[str, object]:
    path = _safe_asset_name("login-slides", row.id, row.image_mime)
    media[path] = _decode_image(row.image_data, f"登录轮播图 #{row.id}")
    return {
        "id": row.id,
        "title": row.title,
        "description": row.description,
        "imagePath": path,
        "imageMime": row.image_mime,
        "sortOrder": row.sort_order,
    }


def _wechat_payload(
    row: WxArticle,
    media: dict[str, bytes],
    downloaded: DownloadedImage | None,
) -> dict[str, object]:
    cover_path: str | None = None
    cover_mime: str | None = None
    if downloaded is not None:
        cover_path = _cover_file_name(row.id, downloaded.mime)
        cover_mime = downloaded.mime
        media[cover_path] = downloaded.data
    return {
        "id": row.id,
        "title": row.title,
        "summary": row.summary,
        "date": row.publish_time,
        "articleUrl": row.article_url,
        "coverPath": cover_path,
        "coverMime": cover_mime,
        "source": "wechat",
    }


def _archive_bundle(
    resource_kind: str,
    generated_at: str,
    counts: dict[str, int],
    files: dict[str, bytes],
    manifest_files: dict[str, str],
) -> ShiplyContentBundle:
    resource_key = resource_key_for_kind(resource_kind)
    manifest = {
        "schemaVersion": SHIPLY_SCHEMA_VERSION,
        "resourceKey": resource_key,
        "resourceKind": resource_kind,
        "generatedAt": generated_at,
        "counts": counts,
        "files": manifest_files,
    }
    all_files = {"manifest.json": _json_bytes(manifest), **files}
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(all_files):
            info = zipfile.ZipInfo(
                filename=posixpath.normpath(name), date_time=(1980, 1, 1, 0, 0, 0)
            )
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, all_files[name])
    archive_bytes = output.getvalue()
    return ShiplyContentBundle(
        archive=archive_bytes,
        filename=f"{resource_key}.zip",
        generated_at=generated_at,
        resource_key=resource_key,
        sha256=hashlib.sha256(archive_bytes).hexdigest(),
        counts=counts,
    )


def build_login_content_bundle() -> ShiplyContentBundle:
    """构建仅供未登录页面使用的轮播资源包。"""
    generated_at = datetime.now(UTC).isoformat()
    media: dict[str, bytes] = {}
    factory = get_sync_session_factory()
    with factory() as db:
        slides = (
            db.query(LoginCarouselSlide)
            .filter(LoginCarouselSlide.published.is_(True))
            .order_by(LoginCarouselSlide.sort_order.asc(), LoginCarouselSlide.id.asc())
            .all()
        )
        slide_payload = [_login_slide_payload(row, media) for row in slides]
    counts = {"loginSlides": len(slide_payload), "media": len(media)}
    return _archive_bundle(
        SHIPLY_LOGIN_RESOURCE_KIND,
        generated_at,
        counts,
        {"login_slides.json": _json_bytes(slide_payload), **media},
        {"loginSlides": "login_slides.json"},
    )


def _download_home_covers(rows: list[WxArticle]) -> dict[int, DownloadedImage]:
    with_covers = [row for row in rows if row.cover_url]
    if not with_covers:
        return {}
    worker_count = min(MAX_PARALLEL_COVER_DOWNLOADS, len(with_covers))
    with ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="shiply-cover") as executor:
        downloads = {
            row.id: future
            for row, future in (
                (row, executor.submit(download_cover_image, row.cover_url)) for row in with_covers
            )
        }
        return {row_id: future.result() for row_id, future in downloads.items()}


def build_home_content_bundle() -> ShiplyContentBundle:
    """构建仅供登录后首页与通知页使用的公共资源包。"""
    generated_at = datetime.now(UTC).isoformat()
    media: dict[str, bytes] = {}
    factory = get_sync_session_factory()
    with factory() as db:
        notices = (
            db.query(AdminNotice)
            .filter(AdminNotice.published.is_(True))
            .order_by(AdminNotice.is_pinned.desc(), AdminNotice.id.desc())
            .all()
        )
        articles = db.query(WxArticle).filter(WxArticle.hidden.is_(False)).all()
        articles.sort(key=lambda row: (row.publish_time or "", row.id), reverse=True)
        notice_payload = [_public_notice_payload(row, media) for row in notices]
        downloaded_covers = _download_home_covers(articles)
        article_payload = [
            _wechat_payload(row, media, downloaded_covers.get(row.id)) for row in articles
        ]
    counts = {
        "notices": len(notice_payload),
        "wechatArticles": len(article_payload),
        "media": len(media),
    }
    return _archive_bundle(
        SHIPLY_HOME_RESOURCE_KIND,
        generated_at,
        counts,
        {
            "notices.json": _json_bytes(notice_payload),
            "wechat_articles.json": _json_bytes(article_payload),
            **media,
        },
        {"notices": "notices.json", "wechatArticles": "wechat_articles.json"},
    )
