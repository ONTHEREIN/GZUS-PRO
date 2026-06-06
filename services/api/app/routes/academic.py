import logging
from collections.abc import Callable
from typing import TypeVar

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse

from app.cache_service import load_cache, save_cache
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


def _get_student_id(session: AppSession) -> str:
    client = session.client
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
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="教务系统数据获取失败，请稍后重试",
        ) from exc


def _run_with_cache_fallback(
    resource: str,
    student_id: str,
    call: Callable[[], T],
    params: dict | None = None,
) -> JSONResponse | T:
    try:
        result = _run_academic_call(call)
        try:
            save_cache(student_id, resource, result, params)
        except Exception:
            logger.warning("Failed to save cache for resource=%s", resource, exc_info=True)
        return result
    except HTTPException as exc:
        if exc.status_code == status.HTTP_401_UNAUTHORIZED:
            raise
        try:
            cached = load_cache(student_id, resource, params)
        except Exception:
            logger.warning("Failed to load cache for resource=%s", resource, exc_info=True)
            cached = None
        if cached is not None:
            from app.cache_service import get_cached_at
            try:
                cached_at = get_cached_at(student_id, resource, params)
            except Exception:
                cached_at = None
            cached_at_str = cached_at.isoformat() if cached_at else ""
            logger.info("Serving cached data for resource=%s, cached_at=%s", resource, cached_at_str)
            resp = JSONResponse(content=cached)
            resp.headers["X-Data-Source"] = "cache"
            resp.headers["X-Data-Cached-At"] = cached_at_str
            return resp
        raise


@router.get("/me", response_model=StudentInfo)
def me(request: Request, session: AppSession = Depends(require_session)) -> dict:
    student_id = _get_student_id(session)
    return _run_with_cache_fallback("me", student_id, session.client.get_info)


@router.get("/schedule", response_model=list[ScheduleCourse])
def schedule(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return _run_with_cache_fallback(
        "schedule", student_id, lambda: session.client.get_schedule(year, term), params,
    )


@router.get("/exams", response_model=list[ExamItem])
def exams(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return _run_with_cache_fallback(
        "exams", student_id, lambda: session.client.get_exams(year, term), params,
    )


@router.get("/grades", response_model=list[GradeItem])
def grades(
    year: str | None = None,
    term: str | None = None,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    params = {"year": year, "term": term} if year or term else None
    return _run_with_cache_fallback(
        "grades", student_id, lambda: session.client.get_grades(year, term), params,
    )


@router.get("/attendance", response_model=AttendanceResponse)
def attendance(
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

    return _run_with_cache_fallback("attendance", student_id, call, params)


@router.get("/credits", response_model=list[CreditItem])
def credits(
    request: Request,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    student_id = _get_student_id(session)
    return _run_with_cache_fallback("credits", student_id, session.client.get_credits)


@router.get("/notices", response_model=list[NoticeItem])
def notices(
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
                key = (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                if item.get("title") and key not in seen:
                    seen.add(key)
                    items.append(item)
        return items

    return _run_with_cache_fallback("notices", student_id, call)


@router.get("/notices/detail", response_model=NoticeDetail)
def notice_detail(
    url: str,
    request: Request = None,
    session: AppSession = Depends(require_session),
) -> dict:
    student_id = _get_student_id(session)
    params = {"url": url}
    return _run_with_cache_fallback(
        "notice_detail", student_id, lambda: session.client.get_notice_detail(url), params,
    )
