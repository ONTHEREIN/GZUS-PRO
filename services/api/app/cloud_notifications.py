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
    NotificationPresentation,
    get_sync_session_factory,
    record_maintenance_job_result,
)
from app.ehall_client import EhallAuthenticationError
from app.notice_utils import notice_key, valid_notice_items
from app.push import PushDeliveryResult, send_push_to_student
from app.sessions import decrypt_credentials
from app.school_client import AuthenticationError
from app.school_session_service import (
    SchoolSessionLimitError,
    SchoolSessionSuspendedError,
    ensure_background_clients,
    mark_school_session_invalid,
    suspension_retry_interval,
)
from app.live_activity_data import grade_live_fields, live_activity_priority

logger = logging.getLogger(__name__)
_SHANGHAI = ZoneInfo("Asia/Shanghai")
_COURSE_REMINDER_DISPATCH_GRACE = timedelta(minutes=2)
_SECTION_TIMES = (
    ("09:00", "09:40"), ("09:40", "10:20"), ("10:40", "11:20"), ("11:20", "12:00"),
    ("12:30", "13:10"), ("13:10", "13:50"), ("14:00", "14:40"), ("14:40", "15:20"),
    ("15:30", "16:10"), ("16:10", "16:50"), ("17:00", "17:40"), ("17:40", "18:20"),
    ("19:00", "19:40"), ("19:40", "20:20"), ("20:30", "21:10"), ("21:10", "21:50"),
)
_PERSISTED_EVENT_TYPES = frozenset({
    "new_notice",
    "grade_update",
    "exam_reminder",
    "attendance_update",
    "ecard_reminder",
})


def _grade_snapshot(items: list[dict]) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for item in items:
        course_name = str(item.get("courseName") or item.get("course_name") or "").strip()
        term = str(item.get("term") or "").strip()
        if not course_name:
            continue
        passed = item.get("gradePassed")
        if passed is None:
            passed = item.get("passed")
        snapshot[f"{term}|{course_name}"] = "|".join([
            str(item.get("score") or "").strip(),
            str(item.get("gradePoint") or item.get("grade_point") or "").strip(),
            str(item.get("gradeStatus") or item.get("grade_status") or item.get("status") or "").strip(),
            str(passed if passed is not None else "").strip(),
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
        "priority": live_activity_priority(notification_type, False),
        "endTime": int((datetime.now(timezone.utc) + timedelta(minutes=30)).timestamp() * 1000),
    }


def _ensure_notification_event(
    student_id: str,
    event_key: str,
    notification_type: str,
    title: str,
    body: str,
    extras: dict,
) -> bool:
    """保存动态提醒事件；课程提醒由各端本地计划负责，不写入提醒中心。"""
    if notification_type not in _PERSISTED_EVENT_TYPES:
        return False
    now = datetime.now(timezone.utc)
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id,
            event_key=event_key,
        ).first()
        if row is None:
            row = NotificationDelivery(
                student_id=student_id,
                event_key=event_key,
                notification_type=notification_type,
                title=title,
                body=body,
                extras_json=json.dumps(extras, ensure_ascii=False, separators=(",", ":")),
                expires_at=now + timedelta(days=30),
            )
            db.add(row)
        else:
            row.title = title
            row.body = body
            row.extras_json = json.dumps(extras, ensure_ascii=False, separators=(",", ":"))
            if row.expires_at is None:
                row.expires_at = now + timedelta(days=30)
        db.commit()
    return True


def persist_notification_event(
    student_id: str,
    event_key: str,
    notification_type: str,
    title: str,
    body: str,
    extras: dict,
) -> None:
    """在发送 WebSocket 或远程推送前落库，避免客户端回执先于事件写入。"""
    _ensure_notification_event(student_id, event_key, notification_type, title, body, extras)


def _notification_event_recorded(student_id: str, event_key: str) -> bool:
    with get_sync_session_factory()() as db:
        return db.query(NotificationDelivery).filter(
            NotificationDelivery.student_id == student_id,
            NotificationDelivery.event_key == event_key,
            NotificationDelivery.title.is_not(None),
        ).first() is not None


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
        # 本地前台/后台通道已展示后，无需因 APNs/Web Push 未配置而持续重试。
        return (
            row is not None
            and row.delivery_status != "delivered"
            and row.presented_at is None
        )


def _record_failed_delivery(
    student_id: str,
    event_key: str,
    notification_type: str,
    failure_reason: str,
) -> None:
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).filter_by(
            student_id=student_id, event_key=event_key
        ).first()
        if row is None:
            row = NotificationDelivery(
                student_id=student_id,
                event_key=event_key,
                notification_type=notification_type,
                retry_count=0,
            )
            db.add(row)
        row.delivery_status = "failed"
        row.retry_count = (row.retry_count or 0) + 1
        row.last_failure_reason = failure_reason[:500]
        row.last_attempt_at = datetime.now(timezone.utc)
        row.succeeded_at = None
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
    settings = get_settings()
    account, _ = decrypt_credentials(credentials, settings.credential_encryption_key)
    client, ehall_client, _snapshot = ensure_background_clients(account, credentials)
    return client, ehall_client


def _deliver(student_id: str, event_key: str, notification_type: str, title: str, body: str, extras: dict) -> bool:
    _ensure_notification_event(student_id, event_key, notification_type, title, body, extras)
    if _delivery_recorded(student_id, event_key):
        return False
    failure_reason: str | None = None
    try:
        result = send_push_to_student(student_id, title, body, extras)
        if isinstance(result, PushDeliveryResult):
            delivered = result.regular_delivered
            live_delivered = result.live_activity_delivered
        elif isinstance(result, int):
            delivered = result
            live_delivered = 0
        else:
            raise TypeError("推送通道必须返回 PushDeliveryResult")
    except Exception as exc:
        delivered = 0
        live_delivered = 0
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
        if live_delivered > 0 and failure_reason is None:
            failure_reason = "仅灵动岛投递成功，普通通知未被设备接受"
        _record_failed_delivery(
            student_id,
            event_key,
            notification_type,
            failure_reason or "没有设备接受普通推送",
        )
        logger.warning(
            "notification_delivery_failed",
            extra={
                "student_id": student_id,
                "event_key": event_key,
                "notification_type": notification_type,
                "failure_reason": failure_reason or "没有设备接受普通推送",
                "live_activity_delivered": live_delivered,
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
    """保存并尝试投递一次动态通知；无远程通道时仍保证提醒中心可见。"""
    return (
        _deliver(student_id, event_key, notification_type, title, body, extras)
        or _delivery_recorded(student_id, event_key)
        or _notification_event_recorded(student_id, event_key)
    )


def _is_authentication_failure(error: Exception) -> bool:
    if isinstance(error, (AuthenticationError, EhallAuthenticationError)):
        return True
    response = getattr(error, "response", None)
    if response is not None and getattr(response, "status_code", None) in {401, 403}:
        return True
    message = str(error).lower()
    return any(
        marker in message
        for marker in ("登录状态已失效", "会话已失效", "重新登录", "authentication", "unauthorized")
    )


def _poll_profile_once(
    profile: BackgroundNotificationProfile,
    client: object,
    ehall_client: object | None,
) -> int:
    poll_errors: list[str] = []
    notices_ok = True
    try:
        notices = valid_notice_items(list(client.get_notices()))
    except Exception as exc:
        if _is_authentication_failure(exc):
            raise
        notices = []
        notices_ok = False
        poll_errors.append(f"notices: {type(exc).__name__}: {str(exc)[:200]}")
    if ehall_client is not None:
        try:
            notices.extend(ehall_client.get_notice_items())
        except Exception as exc:
            if _is_authentication_failure(exc):
                raise
            poll_errors.append(f"ehall_notices: {type(exc).__name__}: {str(exc)[:200]}")
            logger.warning("background_ehall_notices_failed", extra={"student_id": profile.student_id}, exc_info=True)
    grades_ok = True
    try:
        grades = list(client.get_grades(None, None))
    except Exception as exc:
        if _is_authentication_failure(exc):
            raise
        grades = []
        grades_ok = False
        poll_errors.append(f"grades: {type(exc).__name__}: {str(exc)[:200]}")
    exams_ok = True
    try:
        exams = list(client.get_exams(None, None))
    except Exception as exc:
        if _is_authentication_failure(exc):
            raise
        exams = []
        exams_ok = False
        poll_errors.append(f"exams: {type(exc).__name__}: {str(exc)[:200]}")
    attendance: list[dict] | None
    attendance_ok = True
    try:
        attendance = list(client.get_attendance(None, None))
    except Exception as exc:
        if _is_authentication_failure(exc):
            raise
        attendance_ok = False
        poll_errors.append(f"attendance: {type(exc).__name__}: {str(exc)[:200]}")
        logger.warning(
            "background_attendance_poll_failed",
            extra={"student_id": profile.student_id},
            exc_info=True,
        )
        attendance = None
    notice_keys = {notice_key(item) for item in notices}
    grade_values = _grade_snapshot(grades)
    exam_keys = {
        f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}|{item.get('seat', '')}"
        for item in exams
    }
    previous_notices = _json_set(profile.notice_keys_json)
    previous_grades = _json_object(profile.grade_snapshot_json)
    previous_exams = _json_set(profile.exam_keys_json)
    previous_attendance = _json_object(profile.attendance_snapshot_json)
    delivered_exam_reminders = _json_set(profile.exam_reminder_keys_json)
    current_time = datetime.now(_SHANGHAI)
    delivered = 0
    saved_notice_keys = set(notice_keys) if notices_ok else set(previous_notices)
    if profile.notices_enabled and notices_ok and previous_notices:
        for item in notices:
            key = notice_key(item)
            event_key = f"notice:{key}"
            if key not in previous_notices or _delivery_retryable(profile.student_id, event_key):
                extras = _transient_live_fields("new_notice", "notices")
                extras["id"] = f"notice:{key}"
                extras["url"] = item.get("url") or ""
                if deliver_notification(profile.student_id, event_key, "new_notice", "新通知", str(item.get("title") or "新通知"), extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    saved_notice_keys.discard(key)
    saved_grade_values = dict(grade_values) if grades_ok else dict(previous_grades)
    if profile.grades_enabled and grades_ok and previous_grades:
        for item in grades:
            key = f"{item.get('term') or ''}|{item.get('courseName') or item.get('course_name') or ''}"
            event_key = f"grade:{key}:{grade_values.get(key)}"
            if key and (previous_grades.get(key) != grade_values.get(key) or _delivery_retryable(profile.student_id, event_key)):
                title = "成绩更新"
                live_grade = grade_live_fields(item)
                course_name = str(item.get("courseName") or "课程")
                score = str(live_grade.get("score") or "").strip()
                status = str(live_grade["gradeStatus"])
                body = f"{course_name}：{score} · {status}" if score else f"{course_name}：{status}"
                extras = _transient_live_fields("grade_update", "grades")
                extras["id"] = f"grade_update:{profile.student_id}:{key}:{grade_values.get(key)}"
                extras.update(live_grade)
                if deliver_notification(profile.student_id, event_key, "grade_update", title, body, extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    if key in previous_grades:
                        saved_grade_values[key] = previous_grades[key]
                    else:
                        saved_grade_values.pop(key, None)
    saved_exam_keys = set(exam_keys) if exams_ok else set(previous_exams)
    if profile.exams_enabled and exams_ok and previous_exams:
        for item in exams:
            key = f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}|{item.get('seat', '')}"
            event_key = f"exam:{key}"
            if key not in previous_exams or _delivery_retryable(profile.student_id, event_key):
                course_name = str(item.get("courseName") or "考试")
                location = str(item.get("location") or "")
                seat = str(item.get("seat") or "")
                body_parts = [f"{course_name} {item.get('time') or ''}".strip()]
                if location:
                    body_parts.append(f"地点：{location}")
                if seat:
                    body_parts.append(f"座位：{seat}")
                extras = {
                    "id": f"exam_reminder:{profile.student_id}:{key}",
                    "type": "exam_reminder",
                    "targetTab": "exams",
                    "shortCriticalText": "考试",
                    "courseName": course_name,
                    "location": location or None,
                    "seat": seat or None,
                    "priority": live_activity_priority("exam_reminder", False),
                }
                if deliver_notification(profile.student_id, event_key, "exam_reminder", "考试提醒", "，".join(body_parts), extras):
                    delivered += 1
                elif not _delivery_recorded(profile.student_id, event_key):
                    saved_exam_keys.discard(key)
    attendance_snapshot = _attendance_snapshot(attendance or [])
    saved_attendance_snapshot = (
        dict(attendance_snapshot) if attendance_ok else dict(previous_attendance)
    )
    if profile.attendance_enabled and attendance_ok and previous_attendance:
        for key, body in _attendance_abnormal_changes(attendance, previous_attendance):
            event_key = f"attendance:{key}:{attendance_snapshot.get(key, '')}"
            extras = _transient_live_fields("attendance_update", "attendance")
            extras["id"] = f"attendance:{profile.student_id}:{key}:{attendance_snapshot.get(key, '')}"
            extras["shortCriticalText"] = "考勤"
            if deliver_notification(profile.student_id, event_key, "attendance_update", "考勤异常", body, extras):
                delivered += 1
            elif not _delivery_recorded(profile.student_id, event_key):
                if key in previous_attendance:
                    saved_attendance_snapshot[key] = previous_attendance[key]
                else:
                    saved_attendance_snapshot.pop(key, None)
    for item in exams if exams_ok else []:
        key = f"{item.get('courseName', '')}|{item.get('time', '')}|{item.get('location', '')}|{item.get('seat', '')}"
        start = _exam_start(str(item.get("time") or ""))
        if start is None or start <= current_time:
            continue
        course_name = str(item.get("courseName") or "考试")
        location = str(item.get("location") or "")
        seat = str(item.get("seat") or "")
        body_parts = [f"{course_name} {item.get('time') or ''}".strip()]
        if location:
            body_parts.append(f"地点：{location}")
        if seat:
            body_parts.append(f"座位：{seat}")
        body = "，".join(body_parts)
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
                        "courseName": course_name,
                        "location": location or None,
                        "seat": seat or None,
                        "priority": live_activity_priority("exam_reminder", True),
                    })
                else:
                    extras = {
                        "type": "exam_reminder",
                        "targetTab": "exams",
                        "shortCriticalText": "考试",
                        "milestone": milestone,
                        "courseName": course_name,
                        "location": location or None,
                        "seat": seat or None,
                        "priority": live_activity_priority("exam_reminder", False),
                    }
                if deliver_notification(profile.student_id, f"exam-time:{reminder_key}", "exam_reminder", "考试提醒", body, extras):
                    delivered += 1
                    delivered_exam_reminders.add(reminder_key)
    profile.notice_keys_json = json.dumps(sorted(saved_notice_keys), ensure_ascii=False)
    profile.grade_snapshot_json = json.dumps(saved_grade_values, ensure_ascii=False, sort_keys=True)
    profile.exam_keys_json = json.dumps(sorted(saved_exam_keys), ensure_ascii=False)
    if attendance_ok:
        profile.attendance_snapshot_json = json.dumps(saved_attendance_snapshot, ensure_ascii=False, sort_keys=True)
    profile.exam_reminder_keys_json = json.dumps(sorted(delivered_exam_reminders), ensure_ascii=False)
    if poll_errors:
        profile.last_error = "; ".join(poll_errors)[:500]
    else:
        profile.last_error = None
    profile.last_checked_at = datetime.now(timezone.utc)
    profile.attendance_last_checked_at = datetime.now(timezone.utc)
    if attendance is None:
        profile.attendance_last_error = next(
            (item.removeprefix("attendance: ") for item in poll_errors if item.startswith("attendance: ")),
            "考勤接口获取失败",
        )
    else:
        profile.attendance_last_error = None
    profile.suspended_at = None
    profile.suspension_reason = None
    profile.next_retry_at = None
    profile.limit_notified_at = None
    return delivered


def _poll_profile(profile: BackgroundNotificationProfile) -> int:
    """轮询单个账号；学校会话失效时只完整重试当前轮一次。"""
    retried = False
    while True:
        try:
            client, ehall_client = _authenticated_client(profile.encrypted_credentials)
            return _poll_profile_once(profile, client, ehall_client)
        except Exception as exc:
            if retried or not _is_authentication_failure(exc):
                raise
            retried = True
            mark_school_session_invalid(profile.student_id)


def _suspend_profile(profile: BackgroundNotificationProfile, reason: str) -> None:
    now = datetime.now(timezone.utc)
    next_retry = now + suspension_retry_interval()
    from app.school_session_service import claim_suspension_notification, suspend_school_session

    suspend_school_session(profile.student_id, reason, next_retry)
    profile.suspended_at = now
    profile.suspension_reason = reason
    profile.next_retry_at = next_retry
    logger.warning(
        "background_notification_suspended",
        extra={"reason": reason, "next_retry_at": next_retry.isoformat()},
    )
    # 每次账号进入暂停窗口只发一次普通通知；失败也不在五分钟轮询中重复轰炸。
    should_notify = profile.limit_notified_at is None and claim_suspension_notification(
        profile.student_id, now
    )
    if should_notify:
        profile.limit_notified_at = now
        _deliver(
            profile.student_id,
            f"background-monitoring-suspended:{profile.student_id}:{int(now.timestamp())}",
            "background_monitoring",
            "后台监测已暂停",
            "校方设备或会话数达到上限，后台监测将在约 1 小时后自动重试。",
            {"type": "background_monitoring", "reason": reason},
        )


def run_background_notification_poll_once() -> dict[str, int]:
    started = datetime.now(timezone.utc)
    delivered = 0
    processed = 0
    poll_error: str | None = None
    with get_sync_session_factory()() as db:
        expired_ids = [
            row.id
            for row in db.query(NotificationDelivery.id)
            .filter(
                NotificationDelivery.expires_at.is_not(None),
                NotificationDelivery.expires_at <= datetime.now(timezone.utc),
            )
            .all()
        ]
        if expired_ids:
            db.query(NotificationPresentation).filter(
                NotificationPresentation.notification_id.in_(expired_ids)
            ).delete(synchronize_session=False)
            db.query(NotificationDelivery).filter(
                NotificationDelivery.id.in_(expired_ids)
            ).delete(synchronize_session=False)
            # 先提交清理事务，再进入会打开独立连接的轮询逻辑，避免 PostgreSQL 锁住事件表。
            db.commit()
        profiles = db.query(BackgroundNotificationProfile).all()
        revoked_accounts: list[str] = []
        for profile in profiles:
            if db.get(CredentialRevocation, profile.credential_fingerprint) is not None:
                db.delete(profile)
                revoked_accounts.append(profile.student_id)
                logger.info("background_notification_profile_removed", extra={"student_id": profile.student_id})
                continue
            processed += 1
            retry_at = profile.next_retry_at
            if retry_at is not None:
                retry_at = retry_at.replace(tzinfo=timezone.utc) if retry_at.tzinfo is None else retry_at
            if profile.suspended_at is not None and retry_at is not None and retry_at > datetime.now(timezone.utc):
                continue
            retry_due = profile.suspended_at is not None
            try:
                delivered += _poll_profile(profile)
            except SchoolSessionSuspendedError:
                continue
            except SchoolSessionLimitError as exc:
                _suspend_profile(profile, exc.reason)
                profile.last_error = exc.reason
                poll_error = exc.reason
            except Exception as exc:
                profile.last_error = f"{type(exc).__name__}: {str(exc)[:300]}"
                if retry_due:
                    profile.next_retry_at = datetime.now(timezone.utc) + suspension_retry_interval()
                    # 保持账号级状态与配置行一致，避免另一轮后台进程绕过小时级恢复窗口。
                    from app.school_session_service import suspend_school_session

                    suspend_school_session(
                        profile.student_id,
                        profile.suspension_reason or "后台监测恢复失败",
                        profile.next_retry_at,
                    )
                checked_at = datetime.now(timezone.utc)
                profile.last_checked_at = checked_at
                profile.attendance_last_checked_at = checked_at
                profile.attendance_last_error = profile.last_error
                poll_error = profile.last_error
                logger.warning("background_notification_poll_failed", extra={"student_id": profile.student_id}, exc_info=True)
        db.commit()
    if revoked_accounts:
        from app.school_session_service import revoke_account_school_access

        for student_id in revoked_accounts:
            revoke_account_school_access(student_id)
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
    first_monday = first_week - timedelta(days=first_week.weekday())
    current = now.astimezone(_SHANGHAI)
    monday = current.date() - timedelta(days=current.weekday())
    week = ((monday - first_monday).days // 7) + 1
    effective_occurrences = []
    has_effective_occurrences = profile.effective_occurrences_json is not None
    if profile.effective_occurrences_json:
        parsed_occurrences = json.loads(profile.effective_occurrences_json)
        if isinstance(parsed_occurrences, list):
            effective_occurrences = [
                item for item in parsed_occurrences
                if isinstance(item, dict) and item.get("date") == current.date().isoformat()
            ]
    result = []
    candidates = effective_occurrences if has_effective_occurrences else [
        course for course in courses
        if course.get("weekday") == current.isoweekday() and week in set(course.get("weeks") or [])
    ]
    for course in candidates:
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
            if not (target <= current < target + _COURSE_REMINDER_DISPATCH_GRACE):
                continue
            course_name = str(course["name"])
            room = str(course.get("classroom") or "")
            body = f"{minutes} 分钟{suffix}：{course_name}{' · ' + room if room else ''}"
            event_key = (
                f"course:{kind}:{course_name}:{current.date().isoformat()}"
                f":{target.hour:02d}:{target.minute:02d}"
            )
            class_start = current.replace(hour=start_hour, minute=start_minute, second=0, microsecond=0)
            class_end = current.replace(hour=end_hour, minute=end_minute, second=0, microsecond=0)
            result.append((event_key, title, body, {
                "id": event_key,
                "eventKey": event_key,
                "type": "course_reminder",
                "targetTab": "schedule",
                "courseName": course_name,
                "location": room,
                "priority": live_activity_priority("course_reminder", True),
                # 本地通知只负责课程提醒；云端 APNs 还需启动实况通知，供锁屏和灵动岛显示倒计时。
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
