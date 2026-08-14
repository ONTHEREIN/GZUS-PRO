import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.cache_service import ExamReminderCache, GradeUpdateCache, NoticeCache
from app.config import get_settings
from app.database import EcardBinding, PushRegistration, get_sync_session_factory
from app.ecard_client import EcardApiError, EcardClient, EcardConfigurationError, EcardRoomRef, safe_float
from app.notice_utils import merge_notices, notice_key, valid_notice_items
from app.push import send_push, send_web_push_to_student
from app.sessions import student_id_of

__all__ = [
    "ExamReminderCache",
    "GradeUpdateCache",
    "NoticeCache",
    "run_ecard_reminder_once",
    "run_ecard_reminder_poller",
    "run_exam_reminder_poller",
    "run_grade_update_poller",
    "run_notice_poller",
]

logger = logging.getLogger(__name__)


def _notice_key(item: dict) -> str:
    return notice_key(item)


def _session_student_id(session) -> str:
    return student_id_of(session)


def _grade_key(item: dict) -> str:
    course_name = str(item.get("courseName") or item.get("course_name") or "").strip()
    term = str(item.get("term") or "").strip()
    return "|".join([term, course_name])


def _grade_signature(item: dict) -> str:
    return "|".join([
        str(item.get("score") or "").strip(),
        str(item.get("gradePoint") or item.get("grade_point") or "").strip(),
    ])


def grade_snapshot(items: list[dict]) -> dict[str, str]:
    return {
        _grade_key(item): _grade_signature(item)
        for item in items
        if _grade_key(item).strip("|")
    }


def changed_grade_items(items: list[dict], previous: dict[str, str]) -> list[dict]:
    current = grade_snapshot(items)
    return [
        item
        for item in items
        if previous.get(_grade_key(item)) is None
        or previous.get(_grade_key(item)) != current.get(_grade_key(item))
    ]


def _session_notices(session) -> list[dict]:
    items = list(session.client.get_notices())
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return valid_notice_items(items)
    try:
        ehall_items = ehall_client.get_notice_items()
    except Exception:
        return valid_notice_items(items)
    return merge_notices(items, ehall_items)


async def run_notice_poller_once(app) -> None:
    cache: NoticeCache = getattr(app.state, "notice_cache", NoticeCache())
    app.state.notice_cache = cache
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    factory = get_sync_session_factory()

    async def poll_session(session_id: str, session) -> None:
        try:
            items = await asyncio.get_event_loop().run_in_executor(
                None, _session_notices, session,
            )
        except Exception:
            logger.warning("notice poll failed for session %s", session_id[:8], exc_info=True)
            return

        current_keys = {_notice_key(item) for item in items}
        previous_keys = cache.get_cached_titles(session_id)
        cache.update(session_id, current_keys)
        if not previous_keys:
            return

        student_id = await asyncio.get_event_loop().run_in_executor(
            None, _session_student_id, session,
        )
        registration_ids: list[str] = []
        if student_id:
            with factory() as db:
                registration_ids = [
                    item.registration_id
                    for item in db.query(PushRegistration)
                    .filter(PushRegistration.student_id == student_id)
                    .all()
                ]

        new_items = [
            item
            for item in items
            if _notice_key(item) not in previous_keys
        ][:5]
        for item in reversed(new_items):
            title = str(item.get("title") or "新通知")
            body = str(item.get("summary") or item.get("category") or "有新的教务通知")
            message = {
                "type": "new_notice",
                "title": "新通知",
                "body": title,
                "url": item.get("url") or "",
                "notice": item,
                "liveUpdate": False,
            }
            await manager.send_to_session(session_id, message)
            if registration_ids:
                await send_push(
                    registration_ids,
                    "新通知",
                    title if not body else f"{title}\n{body}",
                    {"type": "new_notice", "url": item.get("url") or ""},
                )
            if student_id:
                send_web_push_to_student(
                    student_id,
                    "新通知",
                    title if not body else f"{title}\n{body}",
                    {"type": "new_notice", "url": item.get("url") or ""},
                )

    tasks = [
        poll_session(session_id, session)
        for session_id, session in list(sessions.items())
    ]
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


async def run_notice_poller(app):
    while True:
        await run_notice_poller_once(app)
        await asyncio.sleep(get_settings().push_poll_interval_seconds)


def ecard_reminder_message(
    summary: dict,
    power_threshold: float,
    cold_water_threshold: float,
    hot_water_threshold: float,
    enabled_items: list[str],
) -> list[tuple[str, str, str]]:
    """Return list of (item_key, title, body) for items that need reminding."""
    messages = []
    power = safe_float(summary.get("powerBalance"))
    power_text = summary.get("powerText") or "未知"
    cold_text = summary.get("coldWaterText") or "冷水未知"
    hot_text = summary.get("hotWaterText") or "热水未知"
    cold_balance = safe_float(summary.get("coldWaterBalance"))
    hot_balance = safe_float(summary.get("hotWaterBalance"))

    if "power" in enabled_items:
        if power is not None and power < 10:
            messages.append(("power", "电量极低", f"电量极低：{power_text}"))
        elif power is not None and power < power_threshold:
            messages.append(("power", "电量偏低", f"电量偏低：{power_text}"))

    if "cold_water" in enabled_items:
        if cold_balance is not None and cold_balance < cold_water_threshold:
            messages.append(("cold_water", "冷水偏低", f"冷水偏低：{cold_text}"))

    if "hot_water" in enabled_items:
        if hot_balance is not None and hot_balance < hot_water_threshold:
            messages.append(("hot_water", "热水偏低", f"热水偏低：{hot_text}"))

    # If no threshold alerts, send a general summary for enabled items
    if not messages:
        parts = []
        if "power" in enabled_items:
            parts.append(f"电量 {power_text}")
        if "cold_water" in enabled_items:
            parts.append(f"冷水 {cold_text}")
        if "hot_water" in enabled_items:
            parts.append(f"热水 {hot_text}")
        if parts:
            messages.append(("daily", "今日水电费", "今日 " + "，".join(parts)))

    return messages


def ecard_progress_current(
    summary: dict,
    item_key: str,
    power_threshold: float,
    cold_water_threshold: float,
    hot_water_threshold: float,
    enabled_items: list[str],
) -> int:
    pairs = {
        "power": (safe_float(summary.get("powerBalance")), power_threshold),
        "cold_water": (safe_float(summary.get("coldWaterBalance")), cold_water_threshold),
        "hot_water": (safe_float(summary.get("hotWaterBalance")), hot_water_threshold),
    }
    if item_key == "daily":
        values = [
            _balance_progress(balance, threshold)
            for key, (balance, threshold) in pairs.items()
            if key in enabled_items
        ]
        return min(values) if values else 100
    balance, threshold = pairs.get(item_key, (None, 0))
    return _balance_progress(balance, threshold)


def _balance_progress(balance: float | None, threshold: float) -> int:
    if balance is None or threshold <= 0:
        return 100
    return round(max(0, min(100, balance / threshold * 100)))


#: 每个水电项每日最大提醒次数（jobs 轮询与 internal cron 共用）
ECARD_DAILY_REMINDER_LIMIT = 2


def prepare_ecard_reminders(
    binding,
    summary: dict,
    today_key: str,
) -> tuple[list[tuple[str, str, str]], list[str]]:
    """计算绑定当前待发送的水电提醒，并就地更新每日去重计数。

    返回 (待发送的 (item_key, title, body) 列表, 启用的提醒项)。
    调用方负责推送与 db.commit()。
    """
    reminded_times = json.loads(binding.last_reminded_times or "{}")
    if binding.last_reminded_date != today_key:
        reminded_times = {}
        binding.last_reminded_date = today_key

    enabled_items = (
        json.loads(binding.reminder_items)
        if binding.reminder_items
        else ["power", "cold_water", "hot_water"]
    )
    messages = ecard_reminder_message(
        summary,
        power_threshold=binding.low_power_threshold,
        cold_water_threshold=binding.low_cold_water_threshold,
        hot_water_threshold=binding.low_hot_water_threshold,
        enabled_items=enabled_items,
    )

    pending: list[tuple[str, str, str]] = []
    for item_key, title, body in messages:
        count = reminded_times.get(item_key, 0)
        if count >= ECARD_DAILY_REMINDER_LIMIT:
            continue
        reminded_times[item_key] = count + 1
        pending.append((item_key, title, body))
    binding.last_reminded_times = json.dumps(reminded_times)
    return pending, enabled_items


def _next_reminder_at(now: datetime, reminder_times: list[str] | None = None) -> datetime:
    tz = ZoneInfo("Asia/Shanghai")
    local_now = now.astimezone(tz)
    settings = get_settings()
    times = reminder_times or [f"{settings.ecard_daily_reminder_hour:02d}:{settings.ecard_daily_reminder_minute:02d}"]
    
    candidates = []
    for t in times:
        try:
            parts = t.split(":")
            h, m = int(parts[0]), int(parts[1])
        except (ValueError, IndexError):
            continue
        target = local_now.replace(hour=h, minute=m, second=0, microsecond=0)
        if target <= local_now:
            target += timedelta(days=1)
        candidates.append(target)
    
    if not candidates:
        target = local_now.replace(
            hour=settings.ecard_daily_reminder_hour,
            minute=settings.ecard_daily_reminder_minute,
            second=0,
            microsecond=0,
        )
        if target <= local_now:
            target += timedelta(days=1)
        return target.astimezone(timezone.utc)
    
    return min(candidates).astimezone(timezone.utc)


async def run_ecard_reminder_once(app) -> None:
    try:
        # 与 routes/ecard.py 保持一致：统一走 ecard_worker_proxy_origin
        client = EcardClient()
    except EcardConfigurationError:
        logger.info("ECARD_OPENID not configured, skipping ecard reminders")
        return

    factory = get_sync_session_factory()
    with factory() as db:
        bindings = db.query(EcardBinding).filter(EcardBinding.reminder_enabled.is_(True)).all()
        for binding in bindings:
            try:
                room_ref = EcardRoomRef.from_id(binding.room_id)
                summary = client.balance(room_ref, binding.student_id)
            except (ValueError, EcardApiError) as exc:
                logger.warning("ecard reminder failed for %s: %s", binding.student_id, exc)
                continue
            binding.last_summary_json = json.dumps(summary, ensure_ascii=False)
            binding.last_checked_at = datetime.now(timezone.utc)
            binding.updated_at = datetime.now(timezone.utc)

            today = datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
            pending, enabled_items = prepare_ecard_reminders(binding, summary, today)

            for item_key, title, body in pending:
                today_key = today
                progress_current = ecard_progress_current(
                    summary,
                    item_key,
                    binding.low_power_threshold,
                    binding.low_cold_water_threshold,
                    binding.low_hot_water_threshold,
                    enabled_items,
                )
                live_payload = {
                    "id": f"ecard_reminder:{binding.student_id}:{today_key}:{item_key}",
                    "type": "ecard_reminder",
                    "studentId": binding.student_id,
                    "itemKey": item_key,
                    "liveUpdate": True,
                    "style": "progress",
                    "ongoing": False,
                    "shortCriticalText": "水电",
                    "progressMax": 100,
                    "progressCurrent": progress_current,
                    "progress": progress_current / 100,
                }
                registration_ids = [
                    item.registration_id
                    for item in db.query(PushRegistration)
                    .filter(PushRegistration.student_id == binding.student_id)
                    .all()
                ]
                await _send_ecard_ws(app, binding.student_id, title, body, summary, live_payload)
                if registration_ids:
                    await send_push(
                        registration_ids,
                        title,
                        body,
                        live_payload,
                    )
                send_web_push_to_student(
                    binding.student_id,
                    title,
                    body,
                    live_payload,
                )
        db.commit()


async def _send_ecard_ws(app, student_id: str, title: str, body: str, summary: dict, live_payload: dict) -> None:
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    for session_id, session in list(sessions.items()):
        # 直接使用会话持久化学号，避免每个会话一次含照片下载的 JWXT 往返
        current_id = student_id_of(session)
        if current_id and current_id == student_id:
            await manager.send_to_session(
                session_id,
                {
                    **live_payload,
                    "type": "ecard_reminder",
                    "title": title,
                    "body": body,
                    "summary": summary,
                    "studentId": student_id,
                },
            )


async def run_ecard_reminder_poller(app) -> None:
    while True:
        now = datetime.now(timezone.utc)
        # Collect all unique reminder times from bindings
        factory = get_sync_session_factory()
        all_times = set()
        with factory() as db:
            bindings = db.query(EcardBinding).filter(EcardBinding.reminder_enabled.is_(True)).all()
            for b in bindings:
                try:
                    times = json.loads(b.reminder_times) if b.reminder_times else []
                    all_times.update(times)
                except (json.JSONDecodeError, TypeError):
                    pass
        
        next_at = _next_reminder_at(now, list(all_times) if all_times else None)
        await asyncio.sleep(max(1, (next_at - now).total_seconds()))
        await run_ecard_reminder_once(app)


def _exam_key(item: dict) -> str:
    course_name = str(item.get("courseName") or "").strip()
    time = str(item.get("time") or "").strip()
    return f"{course_name}|{time}"


def _parse_exam_start_epoch_ms(time_str: str) -> int | None:
    """Parse exam time like '2025-01-15 09:00-11:00' and return start time as epoch milliseconds."""
    try:
        parts = time_str.strip().split(" ", 1)
        if len(parts) != 2:
            return None
        date_part = parts[0]
        time_range = parts[1]
        start_time_str = time_range.split("-")[0]
        dt_str = f"{date_part} {start_time_str}"
        tz = ZoneInfo("Asia/Shanghai")
        dt = datetime.strptime(dt_str, "%Y-%m-%d %H:%M").replace(tzinfo=tz)
        return int(dt.timestamp() * 1000)
    except Exception:
        return None


async def run_exam_reminder_once(app) -> None:
    cache: ExamReminderCache = getattr(app.state, "exam_reminder_cache", ExamReminderCache())
    app.state.exam_reminder_cache = cache
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    factory = get_sync_session_factory()
    tz = ZoneInfo("Asia/Shanghai")
    today = datetime.now(tz).date()
    now_ms = int(datetime.now(tz).timestamp() * 1000)

    async def poll_session(session_id: str, session) -> None:
        try:
            exams = await asyncio.get_event_loop().run_in_executor(
                None, session.client.get_exams, None, None,
            )
        except Exception:
            logger.warning("exam reminder poll failed for session %s", session_id[:8], exc_info=True)
            return

        today_exams = []
        for exam in exams:
            time_str = str(exam.get("time") or "").strip()
            if not time_str:
                continue
            try:
                date_part = time_str.split(" ", 1)[0]
                exam_date = datetime.strptime(date_part, "%Y-%m-%d").date()
            except (ValueError, IndexError):
                continue
            if exam_date == today:
                today_exams.append(exam)

        if not today_exams:
            return

        student_id = await asyncio.get_event_loop().run_in_executor(
            None, _session_student_id, session,
        )
        registration_ids: list[str] = []
        if student_id:
            with factory() as db:
                registration_ids = [
                    item.registration_id
                    for item in db.query(PushRegistration)
                    .filter(PushRegistration.student_id == student_id)
                    .all()
                ]

        for exam in today_exams:
            key = _exam_key(exam)
            if cache.is_reminded(session_id, key):
                continue
            course_name = str(exam.get("courseName") or "未知科目")
            time_str = str(exam.get("time") or "")
            location = str(exam.get("location") or "")
            body_parts = [f"{course_name} {time_str}"]
            if location:
                body_parts.append(f"地点：{location}")
            body = "，".join(body_parts)
            end_time = _parse_exam_start_epoch_ms(time_str)
            if end_time is not None and end_time <= now_ms:
                cache.mark_reminded(session_id, key)
                continue
            message: dict = {
                "id": f"exam_reminder:{session_id}:{key}",
                "type": "exam_reminder",
                "title": "考试提醒",
                "body": body,
                "courseName": course_name,
                "liveUpdate": True,
                "style": "progress",
                "shortCriticalText": "考试",
                "progressStartTime": now_ms,
                "progressMax": 100,
                "progressCurrent": 0,
                "progress": 0,
            }
            if end_time is not None:
                message["endTime"] = end_time
            await manager.send_to_session(session_id, message)
            extras: dict = {
                "id": f"exam_reminder:{student_id}:{key}",
                "type": "exam_reminder",
                "courseName": course_name,
                "liveUpdate": True,
                "style": "progress",
                "shortCriticalText": "考试",
                "progressStartTime": now_ms,
                "progressMax": 100,
                "progressCurrent": 0,
                "progress": 0,
            }
            if end_time is not None:
                extras["endTime"] = end_time
            if registration_ids:
                await send_push(
                    registration_ids,
                    "考试提醒",
                    body,
                    extras,
                )
            if student_id:
                send_web_push_to_student(
                    student_id,
                    "考试提醒",
                    body,
                    extras,
                )
            cache.mark_reminded(session_id, key)

    tasks = [
        poll_session(session_id, session)
        for session_id, session in list(sessions.items())
    ]
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


async def run_exam_reminder_poller(app) -> None:
    while True:
        await run_exam_reminder_once(app)
        await asyncio.sleep(get_settings().push_poll_interval_seconds)


async def run_grade_update_once(app) -> None:
    cache: GradeUpdateCache = getattr(app.state, "grade_update_cache", GradeUpdateCache())
    app.state.grade_update_cache = cache
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    factory = get_sync_session_factory()

    async def poll_session(session_id: str, session) -> None:
        student_id = await asyncio.get_event_loop().run_in_executor(
            None, _session_student_id, session,
        )
        if not student_id:
            return
        try:
            grades = await asyncio.get_event_loop().run_in_executor(
                None, session.client.get_grades, None, None,
            )
        except Exception:
            logger.warning("grade update poll failed for session %s", session_id[:8], exc_info=True)
            return

        current = grade_snapshot(grades)
        previous = cache.get(student_id)
        cache.update(student_id, current)
        if not previous:
            return

        changed = changed_grade_items(grades, previous)[:3]
        if not changed:
            return

        registration_ids: list[str] = []
        with factory() as db:
            registration_ids = [
                item.registration_id
                for item in db.query(PushRegistration)
                .filter(PushRegistration.student_id == student_id)
                .all()
            ]

        for grade in changed:
            course_name = str(grade.get("courseName") or "课程")
            score = str(grade.get("score") or "").strip()
            title = "成绩更新"
            body = f"{course_name}：{score}" if score else f"{course_name} 已发布成绩"
            payload = {
                "id": f"grade_update:{student_id}:{_grade_key(grade)}:{_grade_signature(grade)}",
                "type": "grade_update",
                "studentId": student_id,
                "title": title,
                "body": body,
                "grade": grade,
                "liveUpdate": True,
                "style": "progress",
                "ongoing": False,
                "shortCriticalText": "成绩",
                "progressMax": 100,
                "progressCurrent": 100,
                "progress": 1,
            }
            await manager.send_to_session(session_id, payload)
            extras = {key: value for key, value in payload.items() if key not in {"title", "body"}}
            if registration_ids:
                await send_push(registration_ids, title, body, extras)
            send_web_push_to_student(student_id, title, body, extras)

    tasks = [
        poll_session(session_id, session)
        for session_id, session in list(sessions.items())
    ]
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


async def run_grade_update_poller(app) -> None:
    while True:
        await run_grade_update_once(app)
        await asyncio.sleep(get_settings().push_poll_interval_seconds)
