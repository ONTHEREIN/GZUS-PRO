import json
from datetime import datetime
from zoneinfo import ZoneInfo

from app.cloud_notifications import (
    _attendance_abnormal_changes,
    _attendance_snapshot,
    _course_reminder_candidates,
    _exam_start,
)
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


def test_attendance_snapshot_only_reports_increased_abnormal_counts():
    previous = _attendance_snapshot([{
        "courseId": "c1", "courseName": "高等数学", "late": 1,
        "leaveEarly": 0, "absent": 0, "leave": 0,
    }])
    changes = _attendance_abnormal_changes([{
        "courseId": "c1", "courseName": "高等数学", "late": 1,
        "leaveEarly": 0, "absent": 1, "leave": 0,
    }], previous)
    assert changes == [("c1", "高等数学：缺勤1次")]

    new_course = _attendance_abnormal_changes(
        [{"courseId": "c2", "courseName": "大学英语", "late": 1}], previous
    )
    assert new_course == [("c2", "大学英语：迟到1次")]


def test_exam_start_parses_range_with_shanghai_timezone():
    value = _exam_start("2026-09-20 09:00-11:00")
    assert value is not None
    assert value.hour == 9
    assert value.tzinfo == ZoneInfo("Asia/Shanghai")
