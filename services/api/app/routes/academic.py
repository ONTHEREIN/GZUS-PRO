import asyncio
import logging
import re
import time
from collections.abc import Callable
from datetime import UTC, datetime
from typing import TypeVar

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse

from app.cache_service import (
    ACADEMIC_CACHE_MAX_AGE_SECONDS,
    load_and_get_cached_at,
    save_cache,
)
from app.notice_utils import merge_notices, valid_notice_items
from app.routes.deps import require_session
from app.schemas import (
    AttendanceResponse,
    CreditItem,
    ExamItem,
    GradeItem,
    NoticeDetail,
    NoticeItem,
    ScheduleCourse,
    StudentInfo,
)
from app.school_client import AuthenticationError, MissingProxySlotError
from app.sessions import AppSession

logger = logging.getLogger(__name__)

router = APIRouter(tags=["academic"])

T = TypeVar("T")

_DASHBOARD_MODULE_TIMEOUT_SECONDS = 8.0

# 正常请求优先读取未过期的云端缓存，避免页面切换和重复打开持续打到学校系统。
# 下拉刷新会带 refresh=true，跳过这一层并更新缓存。
_CACHE_FRESH_SECONDS = {
    "me": 24 * 3600,
    "schedule": 12 * 3600,
    "notices": 10 * 60,
    "attendance": 5 * 60,
    "credits": 12 * 3600,
    "grades": 30 * 60,
    "exams": 60 * 60,
}

_DASHBOARD_MODULE_LABELS = {
    "me": "个人信息",
    "schedule": "课表",
    "notices": "通知",
    "attendance": "考勤",
    "credits": "学分",
    "grades": "成绩",
    "exams": "考试",
    "apps": "常用服务",
    "progress": "业务进度",
}


def _academic_upstream_error_detail(exc: Exception) -> str:
    """将教务系统故障转换为可行动、但不泄露内部实现的提示。"""
    text = str(exc).lower()
    if "timeout" in text or "超时" in text:
        return "学校教务系统响应超时（已自动重试），请稍后再试"
    if "connect" in text or "连接" in text:
        return "无法连接学校教务系统，请检查网络后稍后重试"
    if "json" in text or "数据格式" in text or "parse" in text:
        return "学校教务系统返回的数据格式异常，请稍后重试"
    match = re.search(r"\b([45]\d{2})\b", text)
    if match is not None:
        return f"学校教务系统暂时不可用（上游 HTTP {match.group(1)}），请稍后重试"
    return "学校教务系统请求失败（未返回可用数据），请稍后重试"


def _cached_response(data: dict | list, cached_at: datetime | None) -> JSONResponse:
    cached_at_str = cached_at.isoformat() if cached_at else ""
    response = JSONResponse(content=data)
    response.headers["X-Data-Source"] = "cache"
    response.headers["X-Data-Cached-At"] = cached_at_str
    return response


def _load_cached_data(
    student_id: str,
    resource: str,
    params: dict | None,
    max_age_seconds: int | None,
) -> tuple[dict | list | None, datetime | None]:
    try:
        return load_and_get_cached_at(student_id, resource, params, max_age_seconds)
    except Exception:
        logger.warning("Failed to load cache for resource=%s", resource, exc_info=True)
        return None, None


def _dashboard_module(
    name: str,
    fresh_cache: tuple[dict | list | None, datetime | None],
    fallback_cache: tuple[dict | list | None, datetime | None],
    call: Callable[[], T],
    *,
    empty,
) -> dict:
    started = time.perf_counter()
    cached, cached_at = fresh_cache
    if cached is not None:
        return {
            "status": "empty" if cached == empty else "ok",
            "data": cached,
            "source": "cache",
            "cachedAt": cached_at.isoformat() if cached_at else None,
            "durationMs": round((time.perf_counter() - started) * 1000),
        }
    try:
        data = _run_academic_call(call)
        status_value = "empty" if data == empty else "ok"
        return {
            "status": status_value,
            "data": data,
            "source": "api",
            "durationMs": round((time.perf_counter() - started) * 1000),
        }
    except HTTPException as exc:
        cached, cached_at = fallback_cache
        if cached is not None:
            return {
                "status": "empty" if cached == empty else "ok",
                "data": cached,
                "source": "cache",
                "cachedAt": cached_at.isoformat() if cached_at else None,
                "durationMs": round((time.perf_counter() - started) * 1000),
            }
        return {
            "status": "error",
            "data": empty,
            "source": "api",
            "error": str(exc.detail),
            "durationMs": round((time.perf_counter() - started) * 1000),
        }


def _load_dashboard_caches(
    student_id: str,
    params: dict | None,
    refresh: bool,
) -> dict[str, tuple[tuple[dict | list | None, datetime | None], tuple[dict | list | None, datetime | None]]]:
    cache_params = {
        "me": None,
        "schedule": params,
        "notices": None,
        "attendance": params,
        "credits": None,
        "grades": params,
        "exams": params,
    }
    cache_by_resource = {}
    for resource, resource_params in cache_params.items():
        fresh_cache = (
            (None, None)
            if refresh
            else _load_cached_data(
                student_id,
                resource,
                resource_params,
                _CACHE_FRESH_SECONDS[resource],
            )
        )
        fallback_cache = (
            fresh_cache
            if fresh_cache[0] is not None
            else _load_cached_data(student_id, resource, resource_params, None)
        )
        cache_by_resource[resource] = (fresh_cache, fallback_cache)
    return cache_by_resource


def _save_dashboard_module_caches(
    student_id: str,
    params: dict | None,
    modules: dict[str, dict],
) -> None:
    cache_params = {
        "me": None,
        "schedule": params,
        "notices": None,
        "attendance": params,
        "credits": None,
        "grades": params,
        "exams": params,
    }
    for resource, resource_params in cache_params.items():
        module = modules[resource]
        if module["source"] != "api" or module["status"] == "error":
            continue
        try:
            save_cache(student_id, resource, module["data"], resource_params)
        except Exception:
            logger.warning("Failed to save cache for resource=%s", resource, exc_info=True)


def _dashboard_ehall_module(call: Callable[[], T], *, empty) -> dict:
    started = time.perf_counter()
    try:
        data = call()
        return {
            "status": "empty" if data == empty else "ok",
            "data": data,
            "source": "api",
            "durationMs": round((time.perf_counter() - started) * 1000),
        }
    except Exception as exc:
        logger.warning("Dashboard ehall module failed: %s", exc)
        return {
            "status": "error",
            "data": empty,
            "source": "api",
            "error": "模块暂时不可用",
            "durationMs": round((time.perf_counter() - started) * 1000),
        }


async def _run_dashboard_module(
    name: str,
    empty: T,
    call: Callable[[], dict],
) -> tuple[str, dict]:
    """在独立线程中加载一个首页模块，并限制其最长等待时间。"""
    started = time.perf_counter()
    try:
        module = await asyncio.wait_for(
            asyncio.to_thread(call),
            timeout=_DASHBOARD_MODULE_TIMEOUT_SECONDS,
        )
        return name, module
    except TimeoutError:
        logger.warning(
            "dashboard_module_timeout",
            extra={
                "dashboard_module": name,
                "timeout_seconds": _DASHBOARD_MODULE_TIMEOUT_SECONDS,
            },
        )
        return name, {
            "status": "error",
            "data": empty,
            "source": "api",
            "error": (
                f"{_DASHBOARD_MODULE_LABELS.get(name, name)}模块加载超过 "
                f"{_DASHBOARD_MODULE_TIMEOUT_SECONDS:g} 秒，请稍后重试"
            ),
            "durationMs": round((time.perf_counter() - started) * 1000),
        }
def _get_student_id(session: AppSession) -> str:
    if session.student_account:
        return session.student_account
    client = session.client
    if client is None:
        logger.error("academic: session.client is None for session %s", session.id[:8])
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )
    account = getattr(client, "_account", None)
    if account:
        return account
    return session.student_name or "unknown"


def _run_academic_call(call: Callable[[], T]) -> T:
    try:
        return call()
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except MissingProxySlotError as exc:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail=str(exc),
        ) from exc
    except Exception as exc:
        # Server-side / school-portal error (e.g. JWXT 502, timeout, parse
        # failure).  Surface as 502 so _run_with_cache_fallback can serve the
        # last good cache and the frontend shows an offline banner instead of
        # forcing a relogin.  Only AuthenticationError (handled above) yields
        # 401, since that is the one case where a relogin actually helps.
        logger.warning(
            "Academic API call failed: %s: %s — treating as upstream error",
            type(exc).__name__,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=_academic_upstream_error_detail(exc),
        ) from exc


async def _run_with_cache_fallback(
    resource: str,
    student_id: str,
    call: Callable[[], T],
    params: dict | None = None,
    cache_max_age_seconds: int | None = None,
    refresh: bool = False,
) -> JSONResponse | T:
    loop = asyncio.get_event_loop()
    if not refresh and resource in _CACHE_FRESH_SECONDS:
        cached, cached_at = await loop.run_in_executor(
            None,
            _load_cached_data,
            student_id,
            resource,
            params,
            _CACHE_FRESH_SECONDS[resource],
        )
        if cached is not None:
            logger.info("Serving fresh cached data for resource=%s", resource)
            return _cached_response(cached, cached_at)
    try:
        result = await loop.run_in_executor(None, _run_academic_call, call)
        try:
            await loop.run_in_executor(None, save_cache, student_id, resource, result, params)
        except Exception:
            logger.warning("Failed to save cache for resource=%s", resource, exc_info=True)
        return result
    except HTTPException as exc:
        if (
            exc.status_code == status.HTTP_401_UNAUTHORIZED
            and resource not in {"exams", "attendance"}
        ):
            raise
        cached, cached_at = await loop.run_in_executor(
            None,
            _load_cached_data,
            student_id,
            resource,
            params,
            cache_max_age_seconds,
        )
        if cached is not None:
            cached_at_str = cached_at.isoformat() if cached_at else ""
            logger.info("Serving cached data for resource=%s, cached_at=%s", resource, cached_at_str)
            return _cached_response(cached, cached_at)
        raise


@router.get("/me", response_model=StudentInfo)
async def me(
    request: Request,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> dict:
    student_id = _get_student_id(session)
    return await _run_with_cache_fallback(
        "me", student_id, session.client.get_info, refresh=refresh
    )


@router.get("/schedule", response_model=list[ScheduleCourse])
async def schedule(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "schedule", student_id, lambda: session.client.get_schedule(year, term), params, refresh=refresh,
    )


@router.get("/exams", response_model=list[ExamItem])
async def exams(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "exams",
        student_id,
        lambda: session.client.get_exams(year, term),
        params,
        ACADEMIC_CACHE_MAX_AGE_SECONDS,
        refresh,
    )


@router.get("/grades", response_model=list[GradeItem])
async def grades(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "grades", student_id, lambda: session.client.get_grades(year, term), params, refresh=refresh,
    )


@router.get("/attendance", response_model=AttendanceResponse)
async def attendance(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> AttendanceResponse:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None

    def call():
        items = session.client.get_attendance(year, term)
        return AttendanceResponse(status="ok", items=items)

    return await _run_with_cache_fallback(
        "attendance",
        student_id,
        call,
        params,
        ACADEMIC_CACHE_MAX_AGE_SECONDS,
        refresh,
    )


@router.get("/credits", response_model=list[CreditItem])
async def credits(
    request: Request,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    return await _run_with_cache_fallback(
        "credits", student_id, session.client.get_credits, refresh=refresh
    )


@router.get("/dashboard")
async def dashboard(
    request: Request,
    year: str | None = None,
    term: str | None = None,
    week: str | None = None,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> dict:
    """Return a home-page snapshot with module-level failures.

    后端聚合首页所需模块，避免前端扇出多次请求。
    """
    trace_id = request.headers.get("X-GZUS-Trace-Id") or f"api-{int(time.time() * 1000)}"
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    dashboard_caches = _load_dashboard_caches(student_id, params, refresh)

    ehall_client = getattr(session, "ehall_client", None)
    module_jobs = [
        _run_dashboard_module(
            "me",
            {},
            lambda: _dashboard_module(
                "me",
                dashboard_caches["me"][0],
                dashboard_caches["me"][1],
                session.client.get_info if session.client else dict,
                empty={},
            ),
        ),
        _run_dashboard_module(
            "schedule",
            [],
            lambda: _dashboard_module(
                "schedule",
                dashboard_caches["schedule"][0],
                dashboard_caches["schedule"][1],
                lambda: session.client.get_schedule(year, term) if session.client else [],
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "notices",
            [],
            lambda: _dashboard_module(
                "notices",
                dashboard_caches["notices"][0],
                dashboard_caches["notices"][1],
                lambda: _merged_public_notices(
                    session.client.get_notices() if session.client else [],
                    ehall_client,
                ),
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "attendance",
            {"status": "empty", "items": []},
            lambda: _dashboard_module(
                "attendance",
                dashboard_caches["attendance"][0],
                dashboard_caches["attendance"][1],
                lambda: {
                    "status": "ok",
                    "items": session.client.get_attendance(year, term),
                }
                if session.client
                else {"status": "empty", "items": []},
                empty={"status": "empty", "items": []},
            ),
        ),
        _run_dashboard_module(
            "credits",
            [],
            lambda: _dashboard_module(
                "credits",
                dashboard_caches["credits"][0],
                dashboard_caches["credits"][1],
                session.client.get_credits if session.client else list,
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "grades",
            [],
            lambda: _dashboard_module(
                "grades",
                dashboard_caches["grades"][0],
                dashboard_caches["grades"][1],
                lambda: session.client.get_grades(year, term) if session.client else [],
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "exams",
            [],
            lambda: _dashboard_module(
                "exams",
                dashboard_caches["exams"][0],
                dashboard_caches["exams"][1],
                lambda: session.client.get_exams(year, term) if session.client else [],
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "apps",
            [],
            lambda: _dashboard_ehall_module(
                lambda: ehall_client.get_applications() if ehall_client else [],
                empty=[],
            ),
        ),
        _run_dashboard_module(
            "progress",
            {"items": []},
            lambda: _dashboard_ehall_module(
                lambda: ehall_client.get_progress_overview()
                if ehall_client
                else {"items": []},
                empty={"items": []},
            ),
        ),
    ]
    modules = dict(await asyncio.gather(*module_jobs))
    _save_dashboard_module_caches(student_id, params, modules)
    modules["ecard"] = {
        "status": "empty",
        "data": {"status": "not_bound"},
        "source": "api",
        "durationMs": 0,
    }
    modules["weather"] = {
        "status": "empty",
        "data": None,
        "source": "client",
        "durationMs": 0,
    }
    return {
        "status": "ok",
        "generatedAt": datetime.now(UTC).isoformat(),
        "traceId": trace_id,
        "modules": modules,
    }


def _merged_public_notices(jwxt_items: list, ehall_client) -> list[dict]:
    """合并 JWXT + ehall + 校历 + 公众号 四路公开通知（供通知页与首页 dashboard 复用）。"""
    items = jwxt_items
    if ehall_client is not None:
        try:
            ehall_items = ehall_client.get_notice_items()
            items = merge_notices(items, ehall_items)
        except Exception:
            logger.exception("ehall notices merge failed")
    try:
        from app.routes.admin import list_published_admin_notices

        items.extend(list_published_admin_notices())
    except Exception:
        logger.exception("admin notices merge failed")
    try:
        from app.wechat_service import list_visible_articles

        items.extend(list_visible_articles())
    except Exception:
        logger.exception("wechat articles merge failed")
    return valid_notice_items(items)


@router.get("/notices", response_model=list[NoticeItem])
async def notices(
    request: Request,
    refresh: bool = False,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)

    def call():
        # 惰性同步兜底：公众号通道配置过且超时未同步时，后台触发一次（不阻塞响应）
        try:
            from app.wechat_service import trigger_lazy_sync

            trigger_lazy_sync()
        except Exception:
            pass
        return _merged_public_notices(
            session.client.get_notices(),
            getattr(session, "ehall_client", None),
        )

    return await _run_with_cache_fallback("notices", student_id, call, refresh=refresh)


@router.get("/notices/detail", response_model=NoticeDetail)
async def notice_detail(
    url: str,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> dict:
    _validate_notice_url(url)
    student_id = _get_student_id(session)
    params = {"url": url}
    return await _run_with_cache_fallback(
        "notice_detail", student_id, lambda: session.client.get_notice_detail(url), params,
    )


def _validate_notice_url(url: str) -> None:
    """仅允许教务系统同源的通知链接，拒绝跨域 URL 防止 SSRF。

    与 school_client._endpoint_from_url 的校验保持一致，但在这里提前
    拦截并返回清晰的 400，而不是被当作上游故障处理成 502。
    """
    from urllib.parse import urlparse

    from app.config import get_settings

    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https", ""):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="无效的通知链接")
    if parsed.netloc:
        base = urlparse(get_settings().jw_base_url)
        if parsed.netloc != base.netloc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="无效的通知链接")
