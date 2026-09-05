import base64
import logging
import re

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.cache_service import load_and_get_cached_at, save_cache
from app.ehall_client import EhallAuthenticationError
from app.leave_service import (
    build_leave_fill_script,
    build_leave_handler_script,
    build_leave_preview,
)
from app.jwxt.normalizers import normalize_schedule_course
from app.routes.deps import require_session
from app.school_client import AuthenticationError, MissingProxySlotError
from app.schemas import (
    EhallAffairItem,
    EhallApplicationItem,
    EhallProgressOverview,
    LeaveAttachmentUploadRequest,
    LeaveAttachmentItem,
    LEAVE_ATTACHMENT_MAX_BYTES,
    LeaveFillRequest,
    LeaveFillResponse,
    LeavePreviewRequest,
    LeavePreviewResponse,
    NoticeItem,
)
from app.sessions import AppSession
from app.staff_service import ensure_staff_loaded, resolve_teacher, staff_candidates_from_records

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ehall", tags=["ehall"])


@router.get("/leave/teachers/search")
def search_leave_teachers(
    keyword: str = Query(min_length=1, max_length=50),
    session: AppSession = Depends(require_session),
) -> dict:
    """实时查询办事大厅组织架构，供请假单选择任课教师经办人。"""
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="缺少办事大厅会话，请重新登录",
        )
    try:
        records = ehall_client.search_staff(keyword)
        return {"items": [candidate.to_dict() for candidate in staff_candidates_from_records(records)]}
    except EhallAuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    except Exception as exc:
        logger.warning("leave teacher search failed: %s: %s", type(exc).__name__, exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=_ehall_upstream_error_detail(exc),
        ) from exc


def _ehall_upstream_error_detail(exc: Exception) -> str:
    """返回办事大厅故障的明确提示，不透出内部响应内容。"""
    text = str(exc).lower()
    if "timeout" in text or "超时" in text:
        return "办事大厅响应超时，请稍后再试"
    if "connect" in text or "连接" in text:
        return "无法连接办事大厅，请检查网络后稍后重试"
    match = re.search(r"\b([45]\d{2})\b", text)
    if match is not None:
        return f"办事大厅暂时不可用（上游 HTTP {match.group(1)}），请稍后重试"
    return "办事大厅请求失败（未返回可用数据），请稍后重试"


def _get_student_id(session: AppSession) -> str:
    client = session.client
    account = getattr(client, "_account", None)
    if account:
        return account
    return session.student_name or "unknown"


def _schedule_cache_params(year: int, term: int) -> dict[str, str]:
    return {"year": str(year), "term": str(term)}


def _with_cache_fallback(resource: str, student_id: str, call):
    """成功时保存缓存并返回结果；失败（非认证错误）时兜底返回上次缓存。

    认证错误不兜底（缓存里的旧会话数据无意义），由调用方自行处理。
    """
    try:
        result = call()
    except EhallAuthenticationError:
        raise
    except Exception:
        try:
            cached, cached_at = load_and_get_cached_at(student_id, resource)
        except Exception:
            logger.warning("Failed to load cache for resource=%s", resource, exc_info=True)
            cached, cached_at = None, None
        if cached is not None:
            logger.info(
                "Serving cached ehall data for resource=%s, cached_at=%s", resource, cached_at
            )
            return cached
        raise
    try:
        save_cache(student_id, resource, result)
    except Exception:
        logger.warning("Failed to save cache for resource=%s", resource, exc_info=True)
    return result


def _load_leave_courses(payload: LeavePreviewRequest, session: AppSession) -> list[dict]:
    if payload.courses:
        return [normalize_schedule_course(course) for course in payload.courses]

    if session.client is None:
        logger.error("ehall: session.client is None for session %s (leave courses)", session.id[:8])
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )

    student_id = _get_student_id(session)
    params = _schedule_cache_params(payload.year, payload.term)
    try:
        courses = session.client.get_schedule(str(payload.year), str(payload.term))
        try:
            save_cache(student_id, "schedule", courses, params)
        except Exception:
            logger.warning("Failed to save schedule cache for leave preview", exc_info=True)
        return [normalize_schedule_course(course) for course in courses]
    except (AuthenticationError, MissingProxySlotError):
        raise
    except Exception as exc:
        logger.warning(
            "leave schedule fetch failed: %s: %s; trying cached schedule",
            type(exc).__name__,
            exc,
            exc_info=True,
        )
        try:
            cached, cached_at = load_and_get_cached_at(student_id, "schedule", params)
        except Exception:
            logger.warning("Failed to load schedule cache for leave preview", exc_info=True)
            cached, cached_at = None, None
        if isinstance(cached, list):
            logger.info("Using cached schedule for leave preview, cached_at=%s", cached_at)
            return [normalize_schedule_course(course) for course in cached]
        raise HTTPException(
            status_code=status.HTTP_424_FAILED_DEPENDENCY,
            detail="课表暂时无法获取，请先刷新课表后再匹配课程",
        ) from exc


def _decode_leave_attachments(attachments: list[LeaveAttachmentItem]) -> list[tuple[str, bytes]]:
    decoded: list[tuple[str, bytes]] = []
    total_bytes = 0
    for attachment in attachments:
        content = base64.b64decode(attachment.attachment_content_base64, validate=True)
        if not content:
            raise ValueError(f"附件不能为空: {attachment.attachment_name}")
        total_bytes += len(content)
        if total_bytes > LEAVE_ATTACHMENT_MAX_BYTES:
            raise ValueError("图片总大小不能超过 7 MB")
        decoded.append((attachment.attachment_name, content))
    return decoded


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
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="办事大厅会话不可用，请重新登录",
        )
    try:
        return _with_cache_fallback(
            "ehall_affairs",
            _get_student_id(session),
            lambda: ehall_client.get_affairs(
                page_size=100,
                max_pages=1,
                request_timeout_seconds=5,
                max_retries=0,
            ),
        )
    except EhallAuthenticationError as exc:
        logger.warning("ehall affairs auth error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="办事大厅会话已失效，请重新登录",
        ) from exc
    except Exception as exc:
        logger.warning("ehall affairs unavailable: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail=_ehall_upstream_error_detail(exc),
        ) from exc


@router.get("/applications", response_model=list[EhallApplicationItem])
def applications(session: AppSession = Depends(require_session)) -> list[dict]:
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="办事大厅会话不可用，请重新登录",
        )
    try:
        return _with_cache_fallback(
            "ehall_applications",
            _get_student_id(session),
            lambda: ehall_client.get_applications(
                page_size=80,
                max_pages=1,
                request_timeout_seconds=5,
            ),
        )
    except EhallAuthenticationError as exc:
        logger.warning("ehall applications auth error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="办事大厅会话已失效，请重新登录",
        ) from exc
    except Exception as exc:
        logger.warning("ehall applications unavailable: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail=_ehall_upstream_error_detail(exc),
        ) from exc


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
    try:
        courses = _load_leave_courses(payload, session)
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
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except MissingProxySlotError as exc:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail=str(exc),
        ) from exc
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning(
            "leave_preview failed: %s: %s — treating as upstream error",
            type(exc).__name__,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="学校系统暂时不可用，请稍后重试",
        ) from exc


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
        courses = _load_leave_courses(payload, session)
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
        attachments = _decode_leave_attachments(payload.attachments)
        form_url = ehall_client.leave_application_url()
        return {
            "status": "needs_manual" if unmatched_teachers else "filled",
            "message": "请选择任课教师经办人"
            if unmatched_teachers
            else "请打开请假单，页面加载后将自动填写并上传附件",
            "items": preview["items"],
            "unmatchedTeachers": unmatched_teachers,
            "matchedTeachers": matched_teachers,
            "teacherCandidates": teacher_candidates,
            "formUrl": form_url,
            "fillScript": fill_script,
            "handlerScript": handler_script,
            "attachmentUploaded": False,
            "attachmentUploadedCount": 0,
            "attachmentTotal": len(attachments),
        }
    except EhallAuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except MissingProxySlotError as exc:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail=str(exc),
        ) from exc
    except HTTPException:
        raise
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    except base64.binascii.Error as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="附件内容不是有效 Base64"
        ) from exc
    except Exception as exc:
        logger.warning(
            "leave_fill failed: %s: %s — treating as upstream error",
            type(exc).__name__,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="学校系统暂时不可用，请稍后重试",
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
        content = base64.b64decode(payload.attachment_content_base64, validate=True)
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
