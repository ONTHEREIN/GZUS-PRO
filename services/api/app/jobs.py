import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.config import get_settings
from app.database import EcardBinding, PushRegistration, get_sync_session_factory
from app.ecard_client import EcardApiError, EcardClient, EcardConfigurationError, EcardRoomRef, safe_float
from app.push import send_push

logger = logging.getLogger(__name__)


class NoticeCache:
    def __init__(self) -> None:
        self._titles_by_session: dict[str, set[str]] = {}

    def get_cached_titles(self, session_id: str) -> set[str]:
        return set(self._titles_by_session.get(session_id, set()))

    def update(self, session_id: str, titles: set[str]) -> None:
        self._titles_by_session[session_id] = set(titles)

    def remove(self, session_id: str) -> None:
        self._titles_by_session.pop(session_id, None)


def _notice_key(item: dict) -> str:
    title = str(item.get("title") or "").strip()
    url = str(item.get("url") or "").strip()
    category = str(item.get("category") or "").strip()
    return "|".join([category, title, url])


def _session_student_id(session) -> str:
    try:
        info = session.client.get_info()
    except Exception:
        return ""
    return str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")


def _session_notices(session) -> list[dict]:
    items = list(session.client.get_notices())
    ehall_client = getattr(session, "ehall_client", None)
    if ehall_client is None:
        return items
    try:
        ehall_items = ehall_client.get_notice_items()
    except Exception:
        return items
    seen = {_notice_key(item) for item in items}
    for item in ehall_items:
        if item.get("title") and _notice_key(item) not in seen:
            seen.add(_notice_key(item))
            items.append(item)
    return items


async def run_notice_poller_once(app) -> None:
    cache: NoticeCache = getattr(app.state, "notice_cache", NoticeCache())
    app.state.notice_cache = cache
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    factory = get_sync_session_factory()

    with factory() as db:
        for session_id, session in list(sessions.items()):
            try:
                items = _session_notices(session)
            except Exception:
                logger.warning("notice poll failed for session %s", session_id[:8], exc_info=True)
                continue

            current_keys = {_notice_key(item) for item in items if item.get("title")}
            previous_keys = cache.get_cached_titles(session_id)
            cache.update(session_id, current_keys)
            if not previous_keys:
                continue

            student_id = _session_student_id(session)
            registration_ids: list[str] = []
            if student_id:
                registration_ids = [
                    item.registration_id
                    for item in db.query(PushRegistration)
                    .filter(PushRegistration.student_id == student_id)
                    .all()
                ]

            new_items = [
                item
                for item in items
                if item.get("title") and _notice_key(item) not in previous_keys
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
                }
                await manager.send_to_session(session_id, message)
                if registration_ids:
                    await send_push(
                        registration_ids,
                        "新通知",
                        title if not body else f"{title}\n{body}",
                        {"type": "new_notice", "url": item.get("url") or ""},
                    )


async def run_notice_poller(app):
    while True:
        await run_notice_poller_once(app)
        await asyncio.sleep(get_settings().push_poll_interval_seconds)


def ecard_reminder_message(summary: dict, threshold: float) -> tuple[str, str]:
    power = safe_float(summary.get("powerBalance"))
    power_text = summary.get("powerText") or "未知"
    cold_text = summary.get("coldWaterText") or "冷水未知"
    hot_text = summary.get("hotWaterText") or "热水未知"
    if power is not None and power < 10:
        return "电量极低", f"电量极低：{power_text}"
    if power is not None and power < threshold:
        return "电量偏低", f"电量偏低：{power_text}"
    return "今日水电费", f"今日电量 {power_text}，冷水 {cold_text}，热水 {hot_text}"


def _next_reminder_at(now: datetime) -> datetime:
    settings = get_settings()
    tz = ZoneInfo("Asia/Shanghai")
    local_now = now.astimezone(tz)
    target = local_now.replace(
        hour=settings.ecard_daily_reminder_hour,
        minute=settings.ecard_daily_reminder_minute,
        second=0,
        microsecond=0,
    )
    if target <= local_now:
        target += timedelta(days=1)
    return target.astimezone(UTC)


async def run_ecard_reminder_once(app) -> None:
    try:
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
            if binding.last_reminded_date == today:
                continue
            title, body = ecard_reminder_message(summary, binding.low_power_threshold)
            registration_ids = [
                item.registration_id
                for item in db.query(PushRegistration)
                .filter(PushRegistration.student_id == binding.student_id)
                .all()
            ]
            await _send_ecard_ws(app, binding.student_id, title, body, summary)
            if registration_ids:
                await send_push(
                    registration_ids,
                    title,
                    body,
                    {"type": "ecard_reminder", "studentId": binding.student_id},
                )
            binding.last_reminded_date = today
        db.commit()


async def _send_ecard_ws(app, student_id: str, title: str, body: str, summary: dict) -> None:
    sessions = getattr(app.state.sessions, "_sessions", {})
    manager = app.state.ws_manager
    for session_id, session in list(sessions.items()):
        try:
            info = session.client.get_info()
        except Exception:
            continue
        current_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
        if current_id == student_id:
            await manager.send_to_session(
                session_id,
                {
                    "type": "ecard_reminder",
                    "title": title,
                    "body": body,
                    "summary": summary,
                },
            )


async def run_ecard_reminder_poller(app) -> None:
    while True:
        now = datetime.now(timezone.utc)
        next_at = _next_reminder_at(now)
        await asyncio.sleep(max(1, (next_at - now).total_seconds()))
        await run_ecard_reminder_once(app)
