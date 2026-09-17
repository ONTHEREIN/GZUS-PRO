"""用户显式授权的后台持续通知设置。"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, status
from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.database import (
    BackgroundNotificationProfile,
    CredentialRevocation,
    NotificationDelivery,
    NotificationPresentation,
    get_sync_session_factory,
)
from app.routes.deps import require_session
from app.schemas import (
    BackgroundNotificationAccessRequest,
    BackgroundNotificationStatus,
    CourseReminderSyncRequest,
    NotificationEvent,
    NotificationEventList,
    NotificationPreferencesUpdate,
)
from app.sessions import (
    AppSession,
    credential_fingerprint,
    decrypt_credential_payload,
    decrypt_credentials,
    student_id_of,
)

router = APIRouter(prefix="/notifications", tags=["notifications"])


def _student_id(session: AppSession) -> str:
    student_id = student_id_of(session)
    if not student_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期，请重新登录")
    return student_id


def _status(
    row: BackgroundNotificationProfile | None,
    student_id: str | None,
) -> BackgroundNotificationStatus:
    suspended = bool(row is not None and row.suspended_at is not None)
    suspension_reason = row.suspension_reason if row is not None else None
    next_retry_at = row.next_retry_at if row is not None else None
    if row is not None and student_id and not suspended:
        from app.school_session_service import get_school_account_session

        shared = get_school_account_session(student_id)
        if shared is not None and shared.suspended_at is not None:
            suspended = True
            suspension_reason = shared.suspension_reason
            next_retry_at = shared.next_retry_at
    if row is None:
        return BackgroundNotificationStatus(
            enabled=False,
            courseRemindersEnabled=False,
            lastCheckedAt=None,
            lastError=None,
            courseSyncError=None,
            noticesEnabled=True,
            gradesEnabled=True,
            examsEnabled=True,
            attendanceEnabled=True,
            attendanceLastCheckedAt=None,
            attendanceLastError=None,
            suspended=suspended,
            suspensionReason=suspension_reason,
            nextRetryAt=next_retry_at,
        )
    return BackgroundNotificationStatus(
        enabled=True,
        courseRemindersEnabled=row.course_reminders_enabled,
        lastCheckedAt=row.last_checked_at,
        lastError=row.last_error,
        courseSyncError=row.course_sync_error,
        noticesEnabled=row.notices_enabled,
        gradesEnabled=row.grades_enabled,
        examsEnabled=row.exams_enabled,
        attendanceEnabled=row.attendance_enabled,
        attendanceLastCheckedAt=row.attendance_last_checked_at,
        attendanceLastError=row.attendance_last_error,
        suspended=suspended,
        suspensionReason=suspension_reason,
        nextRetryAt=next_retry_at,
    )


@router.patch("/preferences", response_model=BackgroundNotificationStatus)
def patch_notification_preferences(
    payload: NotificationPreferencesUpdate,
    session: AppSession = Depends(require_session),
) -> BackgroundNotificationStatus:
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="请先开启后台持续通知")
        updates = payload.model_dump(exclude_unset=True, by_alias=False)
        for field, value in updates.items():
            setattr(row, field, value)
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _status(row, student_id)


@router.get("/background", response_model=BackgroundNotificationStatus)
def get_background_notification_status(session: AppSession = Depends(require_session)) -> BackgroundNotificationStatus:
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        return _status(row, student_id)


def _notification_event(row: NotificationDelivery) -> NotificationEvent:
    if not row.title or row.body is None:
        raise RuntimeError(f"通知事件 {row.event_key} 缺少展示内容")
    extras = json.loads(row.extras_json or "{}")
    if not isinstance(extras, dict):
        raise RuntimeError(f"通知事件 {row.event_key} 的 extras 不是对象")
    return NotificationEvent(
        id=row.event_key,
        type=row.notification_type,
        title=row.title,
        body=row.body,
        extras=extras,
        createdAt=row.created_at,
        expiresAt=row.expires_at,
        presentedAt=row.presented_at,
        readAt=row.read_at,
    )


def _require_installation_id(value: str | None) -> str:
    installation_id = (value or "").strip()
    if not installation_id or len(installation_id) > 128:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少有效的安装实例 ID")
    return installation_id


@router.get("/events", response_model=NotificationEventList)
def list_notification_events(session: AppSession = Depends(require_session)) -> NotificationEventList:
    """读取当前用户最近 30 天的动态提醒记录。"""
    student_id = _student_id(session)
    now = datetime.now(timezone.utc)
    with get_sync_session_factory()() as db:
        rows = (
            db.query(NotificationDelivery)
            .filter(
                NotificationDelivery.student_id == student_id,
                NotificationDelivery.title.is_not(None),
                (NotificationDelivery.expires_at.is_(None) | (NotificationDelivery.expires_at > now)),
            )
            .order_by(NotificationDelivery.created_at.desc())
            .limit(100)
            .all()
        )
        return NotificationEventList(events=[_notification_event(row) for row in rows])


@router.get("/events/pending", response_model=NotificationEventList)
def list_pending_notification_events(
    session: AppSession = Depends(require_session),
    installation_id: str | None = Header(None, alias="X-Installation-Id"),
) -> NotificationEventList:
    """读取当前安装实例尚未展示的动态提醒。"""
    student_id = _student_id(session)
    installation = _require_installation_id(installation_id)
    now = datetime.now(timezone.utc)
    with get_sync_session_factory()() as db:
        rows = (
            db.query(NotificationDelivery)
            .filter(
                NotificationDelivery.student_id == student_id,
                NotificationDelivery.title.is_not(None),
                (NotificationDelivery.expires_at.is_(None) | (NotificationDelivery.expires_at > now)),
                ~db.query(NotificationPresentation)
                .filter(
                    NotificationPresentation.notification_id == NotificationDelivery.id,
                    NotificationPresentation.installation_id == installation,
                )
                .exists(),
            )
            .order_by(NotificationDelivery.created_at.asc())
            .limit(100)
            .all()
        )
        return NotificationEventList(events=[_notification_event(row) for row in rows])


@router.post("/events/{event_id}/presented")
def mark_notification_presented(
    event_id: str,
    session: AppSession = Depends(require_session),
    installation_id: str | None = Header(None, alias="X-Installation-Id"),
) -> dict[str, str]:
    """记录某安装实例已经展示了通知。"""
    student_id = _student_id(session)
    installation = _require_installation_id(installation_id)
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id,
            event_key=event_id,
        ).first()
        if row is None or row.title is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="通知事件不存在")
        existing = db.query(NotificationPresentation).filter_by(
            notification_id=row.id,
            installation_id=installation,
        ).first()
        if existing is None:
            db.add(NotificationPresentation(
                notification_id=row.id,
                student_id=student_id,
                installation_id=installation,
            ))
        if row.presented_at is None:
            row.presented_at = datetime.now(timezone.utc)
        try:
            db.commit()
        except IntegrityError:
            # 同一安装实例可能由前台与原生服务并发回执；唯一键让回执保持幂等。
            db.rollback()
    return {"status": "ok"}


@router.post("/events/{event_id}/read")
def mark_notification_read(
    event_id: str,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    """标记当前用户已经阅读通知记录。"""
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id,
            event_key=event_id,
        ).first()
        if row is None or row.title is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="通知事件不存在")
        row.read_at = datetime.now(timezone.utc)
        db.commit()
    return {"status": "ok"}


@router.put("/background", response_model=BackgroundNotificationStatus)
def put_background_notification_access(
    payload: BackgroundNotificationAccessRequest,
    session: AppSession = Depends(require_session),
) -> BackgroundNotificationStatus:
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        if not payload.enabled:
            if row is not None:
                db.delete(row)
            db.commit()
            from app.school_session_service import release_if_unused

            release_if_unused(student_id)
            return _status(None, student_id)

        if payload.credential_token is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="开启后台持续通知需要账号密码登录凭据")
        try:
            account, _ = decrypt_credentials(
                payload.credential_token,
                get_settings().credential_encryption_key,
                ttl_seconds=24 * 3600,
            )
            _, _, credential_id = decrypt_credential_payload(
                payload.credential_token,
                get_settings().credential_encryption_key,
            )
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="后台授权凭据无效，请重新登录") from exc
        if account != student_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="后台授权账号与当前会话不一致")
        if credential_id is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="请使用最新账号密码登录后再开启后台持续通知")
        fingerprint = credential_fingerprint(credential_id)
        if db.get(CredentialRevocation, fingerprint) is not None:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="当前设备凭据已被撤销，请重新登录")
        if row is None:
            row = BackgroundNotificationProfile(
                student_id=student_id,
                credential_fingerprint=fingerprint,
                encrypted_credentials=payload.credential_token,
            )
            db.add(row)
        else:
            row.credential_fingerprint = fingerprint
            row.encrypted_credentials = payload.credential_token
            row.last_error = None
            row.suspended_at = None
            row.suspension_reason = None
            row.next_retry_at = None
            row.limit_notified_at = None
        if payload.course_reminder is not None:
            reminder = payload.course_reminder
            row.course_reminders_enabled = reminder.enabled
            row.before_start_minutes = reminder.before_start_minutes
            row.before_end_minutes = reminder.before_end_minutes
            row.first_week_start = reminder.first_week_start
            row.courses_json = json.dumps(
                [course.model_dump(by_alias=True) for course in reminder.courses],
                ensure_ascii=False,
                separators=(",", ":"),
            )
            row.effective_occurrences_json = json.dumps(
                [item.model_dump(by_alias=True) for item in reminder.effective_occurrences],
                ensure_ascii=False,
                separators=(",", ":"),
            )
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _status(row, student_id)


@router.put("/course-reminders", response_model=BackgroundNotificationStatus)
def put_cloud_course_reminders(
    payload: CourseReminderSyncRequest,
    session: AppSession = Depends(require_session),
) -> BackgroundNotificationStatus:
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="请先开启后台持续通知")
        row.course_reminders_enabled = payload.enabled
        row.before_start_minutes = payload.before_start_minutes
        row.before_end_minutes = payload.before_end_minutes
        row.first_week_start = payload.first_week_start
        row.courses_json = json.dumps(
            [course.model_dump(by_alias=True) for course in payload.courses],
            ensure_ascii=False,
            separators=(",", ":"),
        )
        row.effective_occurrences_json = json.dumps(
            [item.model_dump(by_alias=True) for item in payload.effective_occurrences],
            ensure_ascii=False,
            separators=(",", ":"),
        )
        row.course_sync_error = None
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _status(row, student_id)
