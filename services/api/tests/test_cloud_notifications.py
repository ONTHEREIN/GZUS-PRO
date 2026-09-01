import json
from datetime import datetime
from zoneinfo import ZoneInfo

from app.cloud_notifications import _course_reminder_candidates
from app.database import BackgroundNotificationProfile


def test_cloud_course_reminder_is_due_at_configured_minute():
    profile = BackgroundNotificationProfile(
        student_id="20260001",
        credential_fingerprint="a" * 64,
        encrypted_credentials="encrypted",
        course_reminders_enabled=True,
        before_start_minutes=10,
        before_end_minutes=5,
        first_week_start="2026-08-31",
        courses_json=json.dumps([
            {
                "name": "高等数学",
                "weekday": 1,
                "startSection": 1,
                "endSection": 2,
                "classroom": "A101",
                "weeks": [2],
            }
        ]),
    )

    candidates = _course_reminder_candidates(
        profile,
        datetime(2026, 9, 7, 8, 50, tzinfo=ZoneInfo("Asia/Shanghai")),
    )

    assert len(candidates) == 1
    assert candidates[0][1] == "即将上课"
    assert candidates[0][3]["type"] == "course_reminder"
