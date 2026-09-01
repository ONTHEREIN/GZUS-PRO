"""持久化后台通知轮询与云端课程提醒调度。"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.database import (
    BackgroundNotificationProfile,
    CredentialRevocation,
    NotificationDelivery,
    get_sync_session_factory,
    record_maintenance_job_result,
)
from app.notice_utils import notice_key, valid_notice_items
from app.push import send_push_to_student
from app.sessions import decrypt_credentials

logger = logging.getLogger(__name__)
_SHANGHAI = ZoneInfo("Asia/Shanghai")
_SECTION_TIMES = (
    ("09:00", "09:40"), ("09:40", "10:20"), ("10:40", "11:20"), ("11:20", "12:00"),
    ("12:30", "13:10"), ("13:10", "13:50"), ("14:00", "14:40"), ("14:40", "15:20"),
    ("15:30", "16:10"), ("16:10", "16:50"), ("17:00", "17:40"), ("17:40", "18:20"),
    ("19:00", "19:40"), ("19:40", "20:20"), ("20:30", "21:10"), ("21:10", "21:50"),
)


def _grade_snapshot(items: list[dict]) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for item in items:
        course_name = str(item.get("courseName") or item.get("course_name") or "").strip()
        term = str(item.get("term") or "").strip()
        if not course_name:
            continue
        snapshot[f"{term}|{course_name}"] = "|".join([
            str(item.get("score") or "").strip(),
            str(item.get("gradePoint") or item.get("grade_point") or "").strip(),
        ])
    return snapshot


def _json_object(value: str | None) -> dict[str, str]:
    if not value:
        return {}
    parsed = json.loads(value)
    if not isinstance(parsed, dict):
        raise ValueError("持久化通知快照格式无效")
    return {str(key): str(item) for key, item in parsed.items()}


def _json_set(value: str | None) -> set[str]:
    if not value:
        return set()
    parsed = json.loads(value)
    if not isinstance(parsed, list):
        raise ValueError("持久化通知快照格式无效")
    return {str(item) for item in parsed}


def _record_delivery(student_id: str, event_key: str, notification_type: str) -> bool:
    with get_sync_session_factory()() as db:
        db.add(NotificationDelivery(
            student_id=student_id,
            event_key=event_key,
            notification_type=notification_type,
        ))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            return False
    return True


def has_background_notification_profile(student_id: str) -> bool:
    """云端授权账户由持久化任务投递，避免在线轮询重复发送。"""
    with get_sync_session_factory()() as db:
        return (
            db.query(BackgroundNotificationProfile)
            .filter_by(student_id=student_id)
            .first()
            is not None
        )


def _authenticated_client(credentials: str):
    from app.cas_auto_login import CasAutoLogin
    from app.ehall_client import EhallClient
    from app.school_client import SchoolSdkClient
    from urllib.parse import quote

    settings = get_settings()
    account, password = decrypt_credentials(credentials, settings.credential_encryption_key)
    cas = CasAutoLogin(
        cas_url=f"{settings.cas_login_url}?service={quote(settings.jwxt_sso_service_url, safe='')}",
        ehall_url=settings.ehall_base_url,
        ehall_service_url=settings.ehall_service_url,
        timeout=settings.cas_login_timeout_seconds,
    )
    result = cas.auto_login(account, password)
    if result.error:
        raise RuntimeError(f"学校登录失败: {result.error}")
    client = SchoolSdkClient(
        base_url=settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
        httpx_client=result.httpx_client,
    )
    client.login_with_cookies(result.cookies, account)
    ehall_client = None
    if result.ehall_auth_token or result.ehall_cookies:
        ehall_client = EhallClient(
            settings.ehall_base_url,
            result.ehall_cookies or "",
            auth_token=result.ehall_auth_token,
            timeout_seconds=settings.request_timeout_seconds,
        )
    return client, ehall_client


def _deliver(student_id: str, event_key: str, notification_type: str, title: str, body: str, extras: dict) -> bool:
    if not _record_delivery(student_id, event_key, notification_type):
        return False
    send_push_to_student(student_id, title, body, extras)
    return True


def _poll_profile(profile: BackgroundNotificationProfile) -> int:
    client, ehall_client = _authenticated_client(profile.encrypted_credentials)
    notices = valid_notice_items(list(client.get_notices()))
    if ehall_client is not None:
        try:
            notices.extend(ehall_client.get_notice_items())
        except Exception:
            logger.warning("background_ehall_notices_failed", extra={"student_id": profile.student_id}, exc_info=True)
    grades = list(client.get_grades(None, None))
    exams = list(client.get_exams(None, None))
    notice_keys = {notice_key(item) for item in notices}
    grade_values = _grade_snapshot(grades)
    exam_keys = {f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}" for item in exams}
    previous_notices = _json_set(profile.notice_keys_json)
    previous_grades = _json_object(profile.grade_snapshot_json)
    previous_exams = _json_set(profile.exam_keys_json)
    delivered = 0
    if previous_notices:
        for item in notices:
            key = notice_key(item)
            if key not in previous_notices and _deliver(profile.student_id, f"notice:{key}", "new_notice", "新通知", str(item.get("title") or "新通知"), {"type": "new_notice", "url": item.get("url") or ""}):
                delivered += 1
    if previous_grades:
        for item in grades:
            key = f"{item.get('term') or ''}|{item.get('courseName') or item.get('course_name') or ''}"
            if key and previous_grades.get(key) != grade_values.get(key):
                title = "成绩更新"
                body = f"{item.get('courseName') or '课程'}：{item.get('score') or '已发布'}"
                if _deliver(profile.student_id, f"grade:{key}:{grade_values.get(key)}", "grade_update", title, body, {"type": "grade_update"}):
                    delivered += 1
    if previous_exams:
        for item in exams:
            key = f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}"
            if key not in previous_exams:
                body = f"{item.get('courseName') or '考试'} {item.get('time') or ''}".strip()
                if _deliver(profile.student_id, f"exam:{key}", "exam_reminder", "考试提醒", body, {"type": "exam_reminder"}):
                    delivered += 1
    profile.notice_keys_json = json.dumps(sorted(notice_keys), ensure_ascii=False)
    profile.grade_snapshot_json = json.dumps(grade_values, ensure_ascii=False, sort_keys=True)
    profile.exam_keys_json = json.dumps(sorted(exam_keys), ensure_ascii=False)
    return delivered


def run_background_notification_poll_once() -> dict[str, int]:
    started = datetime.now(timezone.utc)
    delivered = 0
    processed = 0
    with get_sync_session_factory()() as db:
        profiles = db.query(BackgroundNotificationProfile).all()
        for profile in profiles:
            if db.get(CredentialRevocation, profile.credential_fingerprint) is not None:
                db.delete(profile)
                db.query(NotificationDelivery).filter_by(student_id=profile.student_id).delete()
                logger.info("background_notification_profile_removed", extra={"student_id": profile.student_id})
                continue
            processed += 1
            try:
                delivered += _poll_profile(profile)
                profile.last_error = None
                profile.last_checked_at = datetime.now(timezone.utc)
            except Exception as exc:
                profile.last_error = f"{type(exc).__name__}: {str(exc)[:300]}"
                logger.warning("background_notification_poll_failed", extra={"student_id": profile.student_id}, exc_info=True)
        db.commit()
    duration = int((datetime.now(timezone.utc) - started).total_seconds() * 1000)
    record_maintenance_job_result(
        "background-notifications", started, duration, None, processed, delivered
    )
    return {"processed": processed, "delivered": delivered}


def _course_reminder_candidates(profile: BackgroundNotificationProfile, now: datetime) -> list[tuple[str, str, str, dict]]:
    if not profile.course_reminders_enabled or not profile.courses_json or not profile.first_week_start:
        return []
    courses = json.loads(profile.courses_json)
    first_week = datetime.strptime(profile.first_week_start, "%Y-%m-%d").date()
    current = now.astimezone(_SHANGHAI)
    monday = current.date() - timedelta(days=current.weekday())
    week = ((monday - first_week).days // 7) + 1
    result = []
    for course in courses:
        if course.get("weekday") != current.isoweekday() or week not in set(course.get("weeks") or []):
            continue
        start = int(course["startSection"])
        end = int(course["endSection"])
        for kind, section, minutes, title, suffix in (
            ("start", start, profile.before_start_minutes, "即将上课", "后上课"),
            ("end", end, profile.before_end_minutes, "即将下课", "后下课"),
        ):
            hour, minute = (int(value) for value in _SECTION_TIMES[section - 1][0 if kind == "start" else 1].split(":"))
            target = current.replace(hour=hour, minute=minute, second=0, microsecond=0) - timedelta(minutes=minutes)
            if not (target <= current < target + timedelta(minutes=1)):
                continue
            course_name = str(course["name"])
            room = str(course.get("classroom") or "")
            body = f"{minutes} 分钟{suffix}：{course_name}{' · ' + room if room else ''}"
            event_key = f"course:{kind}:{course_name}:{target.isoformat()}"
            result.append((event_key, title, body, {"type": "course_reminder", "courseName": course_name}))
    return result


def run_course_reminder_dispatch_once() -> dict[str, int]:
    started = datetime.now(timezone.utc)
    now = datetime.now(timezone.utc)
    delivered = 0
    processed = 0
    with get_sync_session_factory()() as db:
        profiles = db.query(BackgroundNotificationProfile).filter_by(course_reminders_enabled=True).all()
        for profile in profiles:
            processed += 1
            for event_key, title, body, extras in _course_reminder_candidates(profile, now):
                if _deliver(profile.student_id, event_key, "course_reminder", title, body, extras):
                    delivered += 1
    duration = int((datetime.now(timezone.utc) - started).total_seconds() * 1000)
    record_maintenance_job_result(
        "course-reminder-dispatch", started, duration, None, processed, delivered
    )
    return {"delivered": delivered}


async def run_background_notification_poller() -> None:
    while True:
        try:
            await asyncio.to_thread(run_background_notification_poll_once)
        except Exception:
            logger.exception("background_notification_poller_failed")
        await asyncio.sleep(get_settings().background_notification_poll_interval_seconds)


async def run_course_reminder_dispatcher() -> None:
    while True:
        try:
            await asyncio.to_thread(run_course_reminder_dispatch_once)
        except Exception:
            logger.exception("course_reminder_dispatcher_failed")
        await asyncio.sleep(get_settings().course_reminder_dispatch_interval_seconds)
