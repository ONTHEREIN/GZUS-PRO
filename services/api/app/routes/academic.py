import asyncio
import logging
from collections.abc import Callable
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


def _run_academic_call(
    call: Callable[[], T],
    session: AppSession | None = None,
    request: Request | None = None,
) -> T:
    """Execute an academic API call with optional auto-relogin on failure.

    When the JWXT call fails (AuthenticationError or other exception) AND
    a session+request are provided, attempts an automatic CAS relogin from
    Vercel's IP and retries the call once.  This is the safety net for the
    case where the Cloudflare Worker edge could not inject fresh cookies.
    """
    try:
        return call()
    except AuthenticationError as exc:
        if session is not None and request is not None:
            if _retry_after_relogin(call, session, request):
                return call()
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except MissingProxySlotError as exc:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail=str(exc),
        ) from exc
    except Exception as exc:
        logger.warning(
            "Academic API call failed: %s: %s — attempting auto-relogin",
            type(exc).__name__,
            exc,
        )
        if session is not None and request is not None:
            if _retry_after_relogin(call, session, request):
                return call()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        ) from exc


def _retry_after_relogin(
    call: Callable[[], T],
    session: AppSession,
    request: Request,
) -> bool:
    """Try auto-relogin; return True if the call should be retried."""
    from app.routes.deps import _try_auto_relogin as do_relogin

    sid = session.id[:8]
    try:
        ok = do_relogin(session, request)
    except Exception:
        logger.warning("Session %s: auto-relogin raised exception", sid, exc_info=True)
        return False
    if not ok:
        logger.warning("Session %s: auto-relogin failed, cannot retry", sid)
        return False
    # Update the cache so deps.require_session won't re-relogin immediately
    from app.routes.deps import _auto_relogin_cache
    from datetime import datetime
    _auto_relogin_cache[session.id] = datetime.now()
    session.last_active_at = datetime.now()
    return True


async def _run_with_cache_fallback(
    resource: str,
    student_id: str,
    call: Callable[[], T],
    params: dict | None = None,
    session: AppSession | None = None,
    request: Request | None = None,
) -> JSONResponse | T:
    loop = asyncio.get_event_loop()
    try:
        result = await loop.run_in_executor(None, _run_academic_call, call, session, request)
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
    return await _run_with_cache_fallback("me", student_id, session.client.get_info, session=session, request=request)


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
        "schedule", student_id, lambda: session.client.get_schedule(year, term), params, session=session, request=request,
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
        "exams", student_id, lambda: session.client.get_exams(year, term), params, session=session, request=request,
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
        "grades", student_id, lambda: session.client.get_grades(year, term), params, session=session, request=request,
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

    return await _run_with_cache_fallback("attendance", student_id, call, params, session=session, request=request)


@router.get("/credits", response_model=list[CreditItem])
async def credits(
    request: Request,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    return await _run_with_cache_fallback("credits", student_id, session.client.get_credits, session=session, request=request)


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

    return await _run_with_cache_fallback("notices", student_id, call, session=session, request=request)


@router.get("/notices/detail", response_model=NoticeDetail)
async def notice_detail(
    url: str,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> dict:
    student_id = _get_student_id(session)
    params = {"url": url}
    return await _run_with_cache_fallback(
        "notice_detail", student_id, lambda: session.client.get_notice_detail(url), params, session=session, request=request,
    )
