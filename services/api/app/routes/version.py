"""App version check route."""

from packaging.version import Version

from fastapi import APIRouter, Query

from app.config import get_settings

router = APIRouter(prefix="/app", tags=["app"])


@router.get("/version")
def check_version(
    platform: str = Query("android", description="客户端平台"),
    current_version: str = Query("", description="当前版本号"),
    current_build: int = Query(0, description="当前构建号"),
) -> dict:
    """检查应用更新，返回最新版本信息。"""
    settings = get_settings()

    latest = settings.app_latest_version
    latest_build = settings.app_latest_build
    min_supported = settings.app_min_supported_version
    download_url = settings.app_download_url
    release_notes = settings.app_release_notes

    # 判断是否需要更新
    update_available = False
    force_update = False

    if current_version:
        try:
            cur = Version(current_version)
            lat = Version(latest)
            update_available = lat > cur
        except Exception:
            # 版本号解析失败时按 build 号比较
            update_available = latest_build > current_build

    # 判断是否强制更新
    if min_supported and current_version:
        try:
            cur = Version(current_version)
            min_v = Version(min_supported)
            force_update = cur < min_v
        except Exception:
            pass

    return {
        "latest_version": latest,
        "latest_build": latest_build,
        "download_url": download_url,
        "release_notes": release_notes,
        "update_available": update_available,
        "force_update": force_update,
        "min_supported_version": min_supported,
    }
