import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from app.cloud_notifications import (
    _attendance_abnormal_changes,
    _attendance_snapshot,
    _course_reminder_candidates,
    end_expired_live_activities,
    _exam_start,
    _transient_live_fields,
)
from app.database import BackgroundNotificationProfile, IosLiveActivityToken, NotificationDelivery, get_sync_session_factory


def test_cloud_course_reminder_is_due_after_dispatch_drift():
    profile = BackgroundNotificationProfile(
        student_id="20260001",
        credential_fingerprint="a" * 64,
        encrypted_credentials="encrypted",
        course_reminders_enabled=True,
        before_start_minutes=10,
        before_end_minutes=5,
        first_week_start="2026-09-01",
        courses_json=json.dumps([
            {
                "name": "高等数学",
                "weekday": 5,
                "startSection": 1,
                "endSection": 2,
                "classroom": "A101",
                "weeks": [1],
            }
        ]),
    )

    candidates = _course_reminder_candidates(
        profile,
        datetime(2026, 9, 4, 8, 51, 30, tzinfo=ZoneInfo("Asia/Shanghai")),
    )

    assert len(candidates) == 1
    assert candidates[0][1] == "即将上课"
    assert candidates[0][3]["type"] == "course_reminder"
    assert candidates[0][3]["eventKey"] == candidates[0][0]
    assert candidates[0][3]["liveUpdate"] is True
    assert candidates[0][3]["liveEvent"] == "start"
    assert candidates[0][3]["ongoing"] is True
    assert candidates[0][3]["endTime"] - candidates[0][3]["startTime"] == 15 * 60 * 1000


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


def test_all_persisted_notification_types_use_a_fifteen_minute_live_window():
    for notification_type, target_tab in (
        ("new_notice", "notices"),
        ("grade_update", "grades"),
        ("attendance_update", "attendance"),
        ("exam_reminder", "exams"),
        ("ecard_reminder", "ecard"),
    ):
        extras = _transient_live_fields(notification_type, target_tab)
        assert extras["liveUpdate"] is True
        assert extras["liveEvent"] == "start"
        assert extras["ongoing"] is True
        assert extras["endTime"] - extras["startTime"] == int(timedelta(minutes=15).total_seconds() * 1000)


def test_expired_event_sends_explicit_live_activity_end(monkeypatch):
    now = datetime.now(ZoneInfo("UTC"))
    with get_sync_session_factory()() as db:
        db.add(NotificationDelivery(
            student_id="20260001",
            event_key="ecard:expired",
            notification_type="ecard_reminder",
            title="水电提醒",
            body="电费偏低",
            extras_json=json.dumps({"type": "ecard_reminder", "id": "ecard:expired"}),
            expires_at=now + timedelta(days=30),
            delivery_expires_at=now - timedelta(seconds=1),
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            token_type="activity",
            token="a" * 64,
            environment="sandbox",
            activity_id="ecard:expired",
        ))
        db.commit()

    calls: list[dict] = []
    def send_end(_student, action, _title, _body, extras):
        calls.append({
            "action": action,
            **extras,
        })
        with get_sync_session_factory()() as db:
            db.query(IosLiveActivityToken).delete()
            db.commit()
        return 1

    monkeypatch.setattr("app.apns_service.send_live_activity_to_student", send_end)
    assert end_expired_live_activities() == 1
    assert calls == [{
        "action": "end",
        "type": "ecard_reminder",
        "id": "ecard:expired",
        "liveEvent": "end",
        "eventKey": "ecard:expired",
        "ongoing": False,
        "dismissImmediately": True,
    }]
    with get_sync_session_factory()() as db:
        assert db.query(NotificationDelivery).one().live_activity_ended_at is not None


def test_expired_activity_retries_when_one_device_end_fails(monkeypatch):
    now = datetime.now(ZoneInfo("UTC"))
    with get_sync_session_factory()() as db:
        db.add(NotificationDelivery(
            student_id="20260001",
            event_key="notice:retry",
            notification_type="new_notice",
            title="新通知",
            body="内容",
            extras_json=json.dumps({"type": "new_notice"}),
            expires_at=now + timedelta(days=30),
            delivery_expires_at=now - timedelta(seconds=1),
        ))
        for token in ("a" * 64, "b" * 64):
            db.add(IosLiveActivityToken(
                student_id="20260001",
                token_type="activity",
                token=token,
                environment="sandbox",
                activity_id="notice:retry",
            ))
        db.commit()

    calls = 0

    def send_end(_student, _action, _title, _body, _extras):
        nonlocal calls
        calls += 1
        with get_sync_session_factory()() as db:
            db.query(IosLiveActivityToken).filter_by(token=("a" if calls == 1 else "b") * 64).delete()
            db.commit()
        return 1

    monkeypatch.setattr("app.apns_service.send_live_activity_to_student", send_end)
    assert end_expired_live_activities() == 0
    with get_sync_session_factory()() as db:
        assert db.query(NotificationDelivery).one().live_activity_ended_at is None
    assert end_expired_live_activities() == 1
    assert calls == 2
