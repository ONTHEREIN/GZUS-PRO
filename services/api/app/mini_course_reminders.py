"""复用云端生效课表与现有课程调度，微信不维护第二套课程判定。"""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from pydantic import TypeAdapter

from app.database import BackgroundNotificationProfile, MiniNotificationAccess, UserSettings, get_sync_session_factory
from app.sessions import AcademicClient, AppSession
from app.wechat_notifications import mini_type_enabled


def sync_mini_courses(student_id: str, client: AcademicClient) -> None:
    if not mini_type_enabled(student_id, "course_reminder"):
        return
    from app.routes.schedule_adjustments import read_adjustments
    from app.widget_schedule import WidgetCourse, WidgetSnapshotRequest, effective_widget_schedule
    now = datetime.now(ZoneInfo("Asia/Shanghai"))
    with get_sync_session_factory()() as db:
        access = db.get(MiniNotificationAccess, student_id)
        if access is None:
            return
        settings = db.query(UserSettings).filter_by(student_id=student_id).first()
        year = settings.selected_academic_year if settings and settings.selected_academic_year else (
            now.year if now.month >= 8 else now.year - 1)
        term = settings.selected_term if settings and settings.selected_term else (
            1 if now.month >= 8 or now.month == 1 else 2)
        first_weeks = json.loads(settings.first_weeks_json or "{}") if settings else {}
        configured = first_weeks.get(f"{year}-{term}")
        seed = date.fromisoformat(configured) if configured else date(year if term == 1 else year + 1,
                                                                       9 if term == 1 else 3, 1)
        first = seed - timedelta(days=seed.weekday())
    courses = TypeAdapter(list[WidgetCourse]).validate_python(client.get_schedule(str(year), str(term)))
    session = AppSession(id="mini-background", client=client, student_account=student_id)
    context = WidgetSnapshotRequest(year=year, term=term, firstWeekStart=first,
                                   overrides=[], pendingAdjustments=[])
    occurrences = effective_widget_schedule(courses, context, read_adjustments(year, term, session))
    rows = [{"date": item.occurrence_date.isoformat(), "name": item.name,
             "startSection": item.start_section, "endSection": item.end_section,
             "classroom": item.classroom, "teacher": item.teacher} for item in occurrences]
    with get_sync_session_factory()() as db:
        access = db.get(MiniNotificationAccess, student_id)
        if access is not None:
            access.first_week_start, access.occurrences_json = first.isoformat(), json.dumps(rows, ensure_ascii=False)
            access.course_sync_error = None
            db.commit()


def dispatch_mini_courses(now: datetime) -> int:
    from app.cloud_notifications import _course_reminder_candidates, persist_notification_event
    with get_sync_session_factory()() as db:
        accesses = db.query(MiniNotificationAccess).all()
        configs = [(row.student_id, row.first_week_start, row.occurrences_json, row.course_sync_error)
                   for row in accesses]
    processed = 0
    for student_id, first_week, occurrences, sync_error in configs:
        if sync_error or not first_week or occurrences is None or not mini_type_enabled(student_id, "course_reminder"):
            continue
        # 只创建计算输入，不修改移动端课程设置。
        profile = BackgroundNotificationProfile(student_id=student_id, course_reminders_enabled=True,
            first_week_start=first_week, courses_json="[]", effective_occurrences_json=occurrences,
            before_start_minutes=10, before_end_minutes=5)
        for event_key, title, body, extras in _course_reminder_candidates(profile, now):
            persist_notification_event(student_id, event_key, "course_reminder", title, body, extras)
            processed += 1
    return processed
