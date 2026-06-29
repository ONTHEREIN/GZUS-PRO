import asyncio
import logging
import time
from collections.abc import Callable
from datetime import datetime, timezone
from typing import TypeVar

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse

from app.cache_service import load_and_get_cached_at, save_cache
from app.routes.deps import require_session
from app.notice_utils import is_valid_notice_item, normalize_notice_item, valid_notice_items
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


def _dashboard_module(name: str, call: Callable[[], T], *, empty) -> dict:
    started = time.perf_counter()
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
        return {
            "status": "error",
            "data": empty,
            "source": "api",
            "error": str(exc.detail),
            "durationMs": round((time.perf_counter() - started) * 1000),
        }


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


def _get_student_id(session: AppSession) -> str:
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
            detail="学校系统暂时不可用，请稍后重试",
        ) from exc


async def _run_with_cache_fallback(
    resource: str,
    student_id: str,
    call: Callable[[], T],
    params: dict | None = None,
) -> JSONResponse | T:
    loop = asyncio.get_event_loop()
    try:
        result = await loop.run_in_executor(None, _run_academic_call, call)
        try:
            await loop.run_in_executor(None, save_cache, student_id, resource, result, params)
        except Exception:
            logger.warning("Failed to save cache for resource=%s", resource, exc_info=True)
        return result
    except HTTPException as exc:
        if exc.status_code == status.HTTP_401_UNAUTHORIZED:
            raise
        try:
            cached, cached_at = await loop.run_in_executor(
                None, load_and_get_cached_at, student_id, resource, params,
            )
        except Exception:
            logger.warning("Failed to load cache for resource=%s", resource, exc_info=True)
            cached, cached_at = None, None
        if cached is not None:
            cached_at_str = cached_at.isoformat() if cached_at else ""
            logger.info("Serving cached data for resource=%s, cached_at=%s", resource, cached_at_str)
            resp = JSONResponse(content=cached)
            resp.headers["X-Data-Source"] = "cache"
            resp.headers["X-Data-Cached-At"] = cached_at_str
            return resp
        raise


@router.get("/me", response_model=StudentInfo)
async def me(request: Request, session: AppSession = Depends(require_session)) -> dict:
    student_id = _get_student_id(session)
    return await _run_with_cache_fallback("me", student_id, session.client.get_info)


@router.get("/schedule", response_model=list[ScheduleCourse])
async def schedule(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "schedule", student_id, lambda: session.client.get_schedule(year, term), params,
    )


@router.get("/exams", response_model=list[ExamItem])
async def exams(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "exams", student_id, lambda: session.client.get_exams(year, term), params,
    )


@router.get("/grades", response_model=list[GradeItem])
async def grades(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return await _run_with_cache_fallback(
        "grades", student_id, lambda: session.client.get_grades(year, term), params,
    )


@router.get("/attendance", response_model=AttendanceResponse)
async def attendance(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> AttendanceResponse:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None

    def call():
        items = session.client.get_attendance(year, term)
        return AttendanceResponse(status="ok", items=items)

    return await _run_with_cache_fallback("attendance", student_id, call, params)


@router.get("/credits", response_model=list[CreditItem])
async def credits(
    request: Request,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    return await _run_with_cache_fallback("credits", student_id, session.client.get_credits)


@router.get("/dashboard")
async def dashboard(
    request: Request,
    year: str | None = None,
    term: str | None = None,
    week: str | None = None,
    session: AppSession = Depends(require_session),
) -> dict:
    """Return a home-page snapshot with module-level failures.

    Cloudflare Worker handles this route for production web traffic.  This
    backend implementation keeps local dev, native clients, and Worker fallback
    on the same wire shape without fanning the frontend out to many endpoints.
    """
    trace_id = request.headers.get("X-GZUS-Trace-Id") or f"api-{int(time.time() * 1000)}"

    def build() -> dict:
        modules = {
            "me": _dashboard_module(
                "me",
                session.client.get_info if session.client else lambda: {},
                empty={},
            ),
            "schedule": _dashboard_module(
                "schedule",
                lambda: session.client.get_schedule(year, term) if session.client else [],
                empty=[],
            ),
            "notices": _dashboard_module(
                "notices",
                session.client.get_notices if session.client else lambda: [],
                empty=[],
            ),
            "attendance": _dashboard_module(
                "attendance",
                lambda: {
                    "status": "ok",
                    "items": session.client.get_attendance(year, term),
                }
                if session.client
                else {"status": "empty", "items": []},
                empty={"status": "empty", "items": []},
            ),
            "credits": _dashboard_module(
                "credits",
                session.client.get_credits if session.client else lambda: [],
                empty=[],
            ),
            "grades": _dashboard_module(
                "grades",
                lambda: session.client.get_grades(year, term) if session.client else [],
                empty=[],
            ),
            "exams": _dashboard_module(
                "exams",
                lambda: session.client.get_exams(year, term) if session.client else [],
                empty=[],
            ),
            "ecard": {
                "status": "empty",
                "data": {"status": "not_bound"},
                "source": "api",
                "durationMs": 0,
            },
            "weather": {
                "status": "empty",
                "data": None,
                "source": "client",
                "durationMs": 0,
            },
        }
        ehall_client = getattr(session, "ehall_client", None)
        modules["apps"] = _dashboard_ehall_module(
            lambda: ehall_client.get_applications() if ehall_client else [],
            empty=[],
        )
        modules["progress"] = _dashboard_ehall_module(
            lambda: ehall_client.get_progress_overview() if ehall_client else {"items": []},
            empty={"items": []},
        )
        return modules

    loop = asyncio.get_event_loop()
    modules = await loop.run_in_executor(None, build)
    return {
        "status": "ok",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "traceId": trace_id,
        "modules": modules,
    }


@router.get("/notices", response_model=list[NoticeItem])
async def notices(
    request: Request,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)

    def call():
        items = session.client.get_notices()
        ehall_client = getattr(session, "ehall_client", None)
        if ehall_client is not None:
            try:
                ehall_items = ehall_client.get_notice_items()
            except Exception:
                ehall_items = []
            seen = {
                (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                for item in items
            }
            for item in ehall_items:
                item = normalize_notice_item(item)
                key = (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                if is_valid_notice_item(item) and key not in seen:
                    seen.add(key)
                    items.append(item)
        return valid_notice_items(items)

    return await _run_with_cache_fallback("notices", student_id, call)


@router.get("/notices/detail", response_model=NoticeDetail)
async def notice_detail(
    url: str,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> dict:
    student_id = _get_student_id(session)
    params = {"url": url}
    return await _run_with_cache_fallback(
        "notice_detail", student_id, lambda: session.client.get_notice_detail(url), params,
    )
