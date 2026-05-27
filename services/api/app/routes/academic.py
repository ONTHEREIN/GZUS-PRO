from collections.abc import Callable
from typing import TypeVar

from fastapi import APIRouter, Depends, HTTPException, status

from app.routes.deps import require_session
from app.schemas import (
    AttendanceResponse,
    CreditItem,
    ExamItem,
    GradeItem,
    NoticeItem,
    ScheduleCourse,
    StudentInfo,
)
from app.school_client import AuthenticationError
from app.sessions import AppSession

router = APIRouter(tags=["academic"])

T = TypeVar("T")


def _run_academic_call(call: Callable[[], T]) -> T:
    try:
        return call()
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - SDK/proxy exceptions are not stable.
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="教务系统数据获取失败，请稍后重试",
        ) from exc


@router.get("/me", response_model=StudentInfo)
def me(session: AppSession = Depends(require_session)) -> dict:
    return _run_academic_call(session.client.get_info)


@router.get("/schedule", response_model=list[ScheduleCourse])
def schedule(
    year: str | None = None,
    term: str | None = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    return _run_academic_call(lambda: session.client.get_schedule(year, term))


@router.get("/exams", response_model=list[ExamItem])
def exams(
    year: str | None = None,
    term: str | None = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    return _run_academic_call(lambda: session.client.get_exams(year, term))


@router.get("/grades", response_model=list[GradeItem])
def grades(
    year: str | None = None,
    term: str | None = None,
    session: AppSession = Depends(require_session),
) -> list[dict]:
    return _run_academic_call(lambda: session.client.get_grades(year, term))


@router.get("/attendance", response_model=AttendanceResponse)
def attendance(
    year: str | None = None,
    term: str | None = None,
    session: AppSession = Depends(require_session),
) -> AttendanceResponse:
    return AttendanceResponse(
        status="ok",
        items=_run_academic_call(lambda: session.client.get_attendance(year, term)),
    )


@router.get("/credits", response_model=list[CreditItem])
def credits(session: AppSession = Depends(require_session)) -> list[dict]:
    return _run_academic_call(session.client.get_credits)


@router.get("/notices", response_model=list[NoticeItem])
def notices(session: AppSession = Depends(require_session)) -> list[dict]:
    return _run_academic_call(session.client.get_notices)
