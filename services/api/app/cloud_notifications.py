"""持久化后台通知轮询与云端课程提醒调度。"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

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


def _attendance_snapshot(items: list[dict]) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for item in items:
        course = str(item.get("courseId") or item.get("courseName") or "").strip()
        if not course:
            continue
        snapshot[course] = json.dumps(
            {
                "courseName": item.get("courseName") or "",
                "late": int(item.get("late") or 0),
                "leaveEarly": int(item.get("leaveEarly") or 0),
                "absent": int(item.get("absent") or 0),
                "leave": int(item.get("leave") or 0),
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    return snapshot


def _attendance_abnormal_changes(
    items: list[dict], previous: dict[str, str]
) -> list[tuple[str, str]]:
    changes: list[tuple[str, str]] = []
    for item in items:
        course_id = str(item.get("courseId") or item.get("courseName") or "").strip()
        if not course_id:
            continue
        old = {}
        if course_id in previous:
            try:
                old = json.loads(previous[course_id])
            except json.JSONDecodeError:
                old = {}
        labels = (("late", "迟到"), ("leaveEarly", "早退"), ("absent", "缺勤"), ("leave", "请假"))
        increased = [
            f"{label}{int(item.get(field) or 0) - int(old.get(field) or 0)}次"
            for field, label in labels
            if int(item.get(field) or 0) > int(old.get(field) or 0)
        ]
        if increased:
            changes.append((course_id, f"{item.get('courseName') or '课程'}：{'、'.join(increased)}"))
    return changes


def _exam_start(value: str) -> datetime | None:
    try:
        date_part, time_range = value.strip().split(" ", 1)
        return datetime.strptime(
            f"{date_part} {time_range.split('-', 1)[0]}", "%Y-%m-%d %H:%M"
        ).replace(tzinfo=_SHANGHAI)
    except (ValueError, IndexError):
        return None


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


def _transient_live_fields(notification_type: str, target_tab: str) -> dict[str, object]:
    return {
        "type": notification_type,
        "targetTab": target_tab,
        "liveUpdate": True,
        "ongoing": False,
        "shortCriticalText": "新动态",
        "progress": 1,
        "endTime": int((datetime.now(timezone.utc) + timedelta(minutes=30)).timestamp() * 1000),
    }


def _delivery_recorded(student_id: str, event_key: str) -> bool:
    with get_sync_session_factory()() as db:
        return (
            db.query(NotificationDelivery)
            .filter_by(
                student_id=student_id,
                event_key=event_key,
                delivery_status="delivered",
            )
            .first()
            is not None
        )


def _delivery_retryable(student_id: str, event_key: str) -> bool:
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id, event_key=event_key
        ).first()
        return row is not None and row.delivery_status != "delivered"


def _remove_unsuccessful_delivery(student_id: str, event_key: str) -> None:
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id, event_key=event_key
        ).first()
        if row is not None and row.delivery_status != "delivered":
            db.delete(row)
            db.commit()


def _record_successful_delivery(
    student_id: str,
    event_key: str,
    notification_type: str,
    delivered: int,
) -> bool:
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id, event_key=event_key
        ).first()
        if row is not None and row.delivery_status == "delivered":
            return False
        if row is None:
            row = NotificationDelivery(
                student_id=student_id,
                event_key=event_key,
                notification_type=notification_type,
                retry_count=1,
            )
            db.add(row)
        else:
            row.retry_count = (row.retry_count or 0) + 1
        row.delivery_status = "delivered"
        row.last_failure_reason = None
        row.last_attempt_at = datetime.now(timezone.utc)
        row.succeeded_at = datetime.now(timezone.utc)
        db.commit()
        logger.info(
            "notification_delivery_recorded",
            extra={
                "student_id": student_id,
                "event_key": event_key,
                "notification_type": notification_type,
                "delivery_id": row.id,
                "delivered_channels": delivered,
                "retry_count": row.retry_count,
            },
        )
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
    if _delivery_recorded(student_id, event_key):
        return False
    failure_reason: str | None = None
    try:
        delivered = send_push_to_student(student_id, title, body, extras)
    except Exception as exc:
        delivered = 0
        failure_reason = f"{type(exc).__name__}: {str(exc)[:300]}"
        logger.warning(
            "notification_delivery_failed",
            extra={
                "student_id": student_id,
                "event_key": event_key,
                "failure_reason": failure_reason,
            },
            exc_info=True,
        )
    if delivered <= 0:
        _remove_unsuccessful_delivery(student_id, event_key)
        logger.warning(
            "notification_delivery_not_recorded",
            extra={
                "student_id": student_id,
                "event_key": event_key,
                "notification_type": notification_type,
                "failure_reason": failure_reason or "没有设备接受推送",
            },
        )
        return False
    return _record_successful_delivery(student_id, event_key, notification_type, delivered)


def deliver_notification(
    student_id: str,
    event_key: str,
    notification_type: str,
    title: str,
    body: str,
    extras: dict,
) -> bool:
    """投递一次持久化通知，并仅在首次成功或已成功去重时返回真。"""
    return _deliver(student_id, event_key, notification_type, title, body, extras) or _delivery_recorded(
        student_id, event_key
    )


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
    attendance: list[dict] | None
    try:
        attendance = list(client.get_attendance(None, None))
    except Exception:
        logger.warning(
            "background_attendance_poll_failed",
            extra={"student_id": profile.student_id},
            exc_info=True,
        )
        attendance = None
    notice_keys = {notice_key(item) for item in notices}
    grade_values = _grade_snapshot(grades)
    exam_keys = {f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}" for item in exams}
    previous_notices = _json_set(profile.notice_keys_json)
    previous_grades = _json_object(profile.grade_snapshot_json)
    previous_exams = _json_set(profile.exam_keys_json)
    previous_attendance = _json_object(profile.attendance_snapshot_json)
    delivered_exam_reminders = _json_set(profile.exam_reminder_keys_json)
    current_time = datetime.now(_SHANGHAI)
    delivered = 0
    saved_notice_keys = set(notice_keys)
    if profile.notices_enabled and previous_notices:
        for item in notices:
            key = notice_key(item)
            event_key = f"notice:{key}"
            if key not in previous_notices or _delivery_retryable(profile.student_id, event_key):
                extras = _transient_live_fields("new_notice", "notices")
                extras["id"] = f"notice:{key}"
                extras["url"] = item.get("url") or ""
                if _deliver(profile.student_id, event_key, "new_notice", "新通知", str(item.get("title") or "新通知"), extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    saved_notice_keys.discard(key)
    saved_grade_values = dict(grade_values)
    if profile.grades_enabled and previous_grades:
        for item in grades:
            key = f"{item.get('term') or ''}|{item.get('courseName') or item.get('course_name') or ''}"
            event_key = f"grade:{key}:{grade_values.get(key)}"
            if key and (previous_grades.get(key) != grade_values.get(key) or _delivery_retryable(profile.student_id, event_key)):
                title = "成绩更新"
                body = f"{item.get('courseName') or '课程'}：{item.get('score') or '已发布'}"
                extras = _transient_live_fields("grade_update", "grades")
                extras["id"] = f"grade_update:{profile.student_id}:{key}:{grade_values.get(key)}"
                if _deliver(profile.student_id, event_key, "grade_update", title, body, extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    if key in previous_grades:
                        saved_grade_values[key] = previous_grades[key]
                    else:
                        saved_grade_values.pop(key, None)
    saved_exam_keys = set(exam_keys)
    if profile.exams_enabled and previous_exams:
        for item in exams:
            key = f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}"
            event_key = f"exam:{key}"
            if key not in previous_exams or _delivery_retryable(profile.student_id, event_key):
                body = f"{item.get('courseName') or '考试'} {item.get('time') or ''}".strip()
                extras = {
                    "id": f"exam_reminder:{profile.student_id}:{key}",
                    "type": "exam_reminder",
                    "targetTab": "exams",
                    "shortCriticalText": "考试",
                }
                if _deliver(profile.student_id, event_key, "exam_reminder", "考试提醒", body, extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    saved_exam_keys.discard(key)
    attendance_snapshot = _attendance_snapshot(attendance or [])
    saved_attendance_snapshot = dict(attendance_snapshot)
    if profile.attendance_enabled and previous_attendance and attendance is not None:
        for key, body in _attendance_abnormal_changes(attendance, previous_attendance):
            event_key = f"attendance:{key}:{attendance_snapshot.get(key, '')}"
            extras = _transient_live_fields("attendance_update", "attendance")
            extras["id"] = f"attendance:{profile.student_id}:{key}:{attendance_snapshot.get(key, '')}"
            extras["shortCriticalText"] = "考勤"
            if _deliver(profile.student_id, event_key, "attendance_update", "考勤异常", body, extras):
                delivered += 1
            elif not _delivery_recorded(profile.student_id, event_key):
                if key in previous_attendance:
                    saved_attendance_snapshot[key] = previous_attendance[key]
                else:
                    saved_attendance_snapshot.pop(key, None)
    for item in exams:
        key = f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}"
        start = _exam_start(str(item.get("time") or ""))
        if start is None or start <= current_time:
            continue
        body = f"{item.get('courseName') or '考试'} {item.get('time') or ''}".strip()
        for milestone, delta in (("24h", timedelta(hours=24)), ("2h", timedelta(hours=2))):
            reminder_key = f"{milestone}:{key}"
            target = start - delta
            if target <= current_time < target + timedelta(minutes=10) and reminder_key not in delivered_exam_reminders:
                if milestone == "2h":
                    extras = _transient_live_fields("exam_reminder", "exams")
                    extras.update({
                        "id": f"exam_reminder:{profile.student_id}:{key}",
                        "shortCriticalText": "考试",
                        "milestone": milestone,
                        "startTime": int(current_time.timestamp() * 1000),
                        "endTime": int(start.timestamp() * 1000),
                        "ongoing": True,
                    })
                else:
                    extras = {
                        "type": "exam_reminder",
                        "targetTab": "exams",
                        "shortCriticalText": "考试",
                        "milestone": milestone,
                    }
                if _deliver(profile.student_id, f"exam-time:{reminder_key}", "exam_reminder", "考试提醒", body, extras):
                    delivered += 1
                    delivered_exam_reminders.add(reminder_key)
    profile.notice_keys_json = json.dumps(sorted(saved_notice_keys), ensure_ascii=False)
    profile.grade_snapshot_json = json.dumps(saved_grade_values, ensure_ascii=False, sort_keys=True)
    profile.exam_keys_json = json.dumps(sorted(saved_exam_keys), ensure_ascii=False)
    if attendance is not None:
        profile.attendance_snapshot_json = json.dumps(saved_attendance_snapshot, ensure_ascii=False, sort_keys=True)
    profile.exam_reminder_keys_json = json.dumps(sorted(delivered_exam_reminders), ensure_ascii=False)
    return delivered


def run_background_notification_poll_once() -> dict[str, int]:
    started = datetime.now(timezone.utc)
    delivered = 0
    processed = 0
    poll_error: str | None = None
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
                poll_error = profile.last_error
                logger.warning("background_notification_poll_failed", extra={"student_id": profile.student_id}, exc_info=True)
        db.commit()
    duration = int((datetime.now(timezone.utc) - started).total_seconds() * 1000)
    record_maintenance_job_result(
        "background-notifications", started, duration, poll_error, processed, delivered
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
            start_hour, start_minute = (int(value) for value in _SECTION_TIMES[start - 1][0].split(":"))
            end_hour, end_minute = (int(value) for value in _SECTION_TIMES[end - 1][1].split(":"))
            hour, minute = (int(value) for value in _SECTION_TIMES[section - 1][0 if kind == "start" else 1].split(":"))
            target = current.replace(hour=hour, minute=minute, second=0, microsecond=0) - timedelta(minutes=minutes)
            if not (target <= current < target + timedelta(minutes=1)):
                continue
            course_name = str(course["name"])
            room = str(course.get("classroom") or "")
            body = f"{minutes} 分钟{suffix}：{course_name}{' · ' + room if room else ''}"
            event_key = f"course:{kind}:{course_name}:{target.isoformat()}"
            class_start = current.replace(hour=start_hour, minute=start_minute, second=0, microsecond=0)
            class_end = current.replace(hour=end_hour, minute=end_minute, second=0, microsecond=0)
            result.append((event_key, title, body, {
                "id": event_key,
                "type": "course_reminder",
                "targetTab": "schedule",
                "courseName": course_name,
                "classroom": room,
                "liveUpdate": True,
                "ongoing": True,
                "shortCriticalText": "课程",
                "startTime": int(class_start.timestamp() * 1000),
                "endTime": int(class_end.timestamp() * 1000),
            }))
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
