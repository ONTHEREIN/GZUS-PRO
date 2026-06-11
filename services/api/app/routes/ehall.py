import base64
import logging

from fastapi import APIRouter, Depends, HTTPException, status

from app.ehall_client import EhallAuthenticationError
from app.leave_service import (
    build_leave_fill_script,
    build_leave_handler_script,
    build_leave_preview,
    leave_days,
)
from app.routes.deps import require_session
from app.schemas import (
    EhallAffairItem,
    EhallApplicationItem,
    EhallProgressOverview,
    LeaveAttachmentUploadRequest,
    LeaveFillRequest,
    LeaveFillResponse,
    LeavePreviewRequest,
    LeavePreviewResponse,
    NoticeItem,
)
from app.sessions import AppSession
from app.staff_service import ensure_staff_loaded, resolve_teacher

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ehall", tags=["ehall"])


@router.get("/tasks", response_model=list[NoticeItem])
def tasks(session: AppSession = Depends(require_session)) -> list[dict]:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return []
    try:
        return ehall_client.get_notice_items()
    except EhallAuthenticationError as exc:
        logger.warning("ehall tasks auth error: %s", exc)
        return []


@router.get("/affairs", response_model=list[EhallAffairItem])
def affairs(session: AppSession = Depends(require_session)) -> list[dict]:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return []
    try:
        return ehall_client.get_affairs()
    except EhallAuthenticationError as exc:
        logger.warning("ehall affairs auth error: %s", exc)
        return []


@router.get("/applications", response_model=list[EhallApplicationItem])
def applications(session: AppSession = Depends(require_session)) -> list[dict]:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return []
    try:
        return ehall_client.get_applications()
    except EhallAuthenticationError as exc:
        logger.warning("ehall applications auth error: %s", exc)
        return []


@router.get("/progress", response_model=EhallProgressOverview)
def progress(session: AppSession = Depends(require_session)) -> dict:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return {"categories": [], "items": []}
    try:
        return ehall_client.get_progress_overview()
    except EhallAuthenticationError as exc:
        logger.warning("ehall progress auth error: %s", exc)
        return {"categories": [], "items": []}


@router.post("/leave/preview", response_model=LeavePreviewResponse)
def leave_preview(
    payload: LeavePreviewRequest,
    session: AppSession = Depends(require_session),
) -> dict:
    if session.client is None:
        logger.error("ehall: session.client is None for session %s (leave_preview)", session.id[:8])
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )
    try:
        courses = session.client.get_schedule(str(payload.year), str(payload.term))
        return build_leave_preview(
            courses,
            start_date=payload.start_date,
            end_date=payload.end_date,
            year=payload.year,
            term=payload.term,
            first_week_start=payload.first_week_start,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.post("/leave/fill", response_model=LeaveFillResponse)
def leave_fill(
    payload: LeaveFillRequest,
    session: AppSession = Depends(require_session),
) -> dict:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return {
            "status": "no_ehall_session",
            "message": "缺少办事大厅会话，请先使用办事大厅统一登录",
            "items": [],
            "unmatchedTeachers": [],
        }
    if session.client is None:
        logger.error("ehall: session.client is None for session %s (leave_fill)", session.id[:8])
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )
    try:
        courses = session.client.get_schedule(str(payload.year), str(payload.term))
        preview = build_leave_preview(
            courses,
            start_date=payload.start_date,
            end_date=payload.end_date,
            year=payload.year,
            term=payload.term,
            first_week_start=payload.first_week_start,
        )
        if preview["hasMissingFields"]:
            return {
                "status": "needs_manual",
                "message": "部分课程缺少必填字段，请补全后再自动填表",
                "items": preview["items"],
                "unmatchedTeachers": [],
            }
        fill_script = build_leave_fill_script(
            start_date=payload.start_date,
            end_date=payload.end_date,
            reason=payload.reason,
            courses=preview["items"],
        )
        cookie_header = getattr(ehall_client, "cookie_header", "")
        ensure_staff_loaded(cookie_header)
        matched_teachers = []
        unmatched_teachers = []
        teacher_candidates = []
        selected_handlers = {
            item.teacher.strip(): item
            for item in payload.teacher_handlers
            if item.teacher.strip()
        }
        for item in preview["items"]:
            teacher = str(item.get("teacher") or "").strip()
            if not teacher:
                continue
            if teacher in selected_handlers:
                handler = selected_handlers[teacher]
                matched_teachers.append(
                    {
                        "teacher": teacher,
                        "userid": handler.userid,
                        "cnName": handler.cn_name,
                        "courseName": item.get("courseName"),
                    }
                )
                continue
            resolution = resolve_teacher(teacher)
            if resolution.match is not None:
                matched_teachers.append(
                    {
                        "teacher": teacher,
                        "userid": resolution.match.userid,
                        "cnName": resolution.match.cn_name,
                        "courseName": item.get("courseName"),
                    }
                )
            else:
                unmatched_teachers.append(teacher)
                teacher_candidates.append(
                    {
                        "teacher": teacher,
                        "candidates": [
                            candidate.to_dict()
                            for candidate in (resolution.candidates or [])
                        ],
                    }
                )
        handler_script = None
        if not unmatched_teachers and matched_teachers:
            handler_script = build_leave_handler_script(matched_teachers)
        content = base64.b64decode(payload.attachment_content_base64)
        result = ehall_client.fill_leave_application(
            start_date=payload.start_date,
            end_date=payload.end_date,
            leave_days=leave_days(payload.start_date, payload.end_date),
            reason=payload.reason,
            courses=preview["items"],
            attachment_name=payload.attachment_name,
            attachment_content=content,
        )
        return {
            "status": "needs_manual" if unmatched_teachers else result.get("status", "needs_manual"),
            "message": "请选择任课教师经办人"
            if unmatched_teachers
            else "已生成请假单并上传附件，打开后将自动办理并停在提交前",
            "items": preview["items"],
            "unmatchedTeachers": unmatched_teachers,
            "matchedTeachers": matched_teachers,
            "teacherCandidates": teacher_candidates,
            "formUrl": result.get("formUrl"),
            "fillScript": result.get("fillScript") or fill_script,
            "handlerScript": result.get("handlerScript") or handler_script,
            "attachmentUploaded": bool(result.get("attachmentUploaded")),
        }
    except EhallAuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    except base64.binascii.Error as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="附件内容不是有效 Base64"
        ) from exc


@router.post("/leave/attachment")
def leave_attachment(
    payload: LeaveAttachmentUploadRequest,
    session: AppSession = Depends(require_session),
) -> dict:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return {"status": "no_ehall_session", "uploaded": False}
    try:
        content = base64.b64decode(payload.attachment_content_base64)
        uploaded = ehall_client.upload_leave_attachment(
            doc_unid=payload.doc_unid,
            process_id=payload.process_id,
            node_name=payload.node_name,
            local_store=payload.local_store,
            attachment_name=payload.attachment_name,
            attachment_content=content,
        )
        return {"status": "ok" if uploaded else "failed", "uploaded": uploaded}
    except EhallAuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except base64.binascii.Error as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="附件内容不是有效 Base64"
        ) from exc
