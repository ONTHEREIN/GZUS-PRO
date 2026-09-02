"""用户显式授权的后台持续通知设置。"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from app.config import get_settings
from app.database import (
    BackgroundNotificationProfile,
    CredentialRevocation,
    NotificationDelivery,
    get_sync_session_factory,
)
from app.routes.deps import require_session
from app.schemas import (
    BackgroundNotificationAccessRequest,
    BackgroundNotificationStatus,
    CourseReminderSyncRequest,
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


def _status(row: BackgroundNotificationProfile | None) -> BackgroundNotificationStatus:
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
        return _status(row)


@router.get("/background", response_model=BackgroundNotificationStatus)
def get_background_notification_status(session: AppSession = Depends(require_session)) -> BackgroundNotificationStatus:
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        row = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        return _status(row)


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
            db.query(NotificationDelivery).filter_by(student_id=student_id).delete()
            db.commit()
            return _status(None)

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
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _status(row)


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
        row.course_sync_error = None
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _status(row)
