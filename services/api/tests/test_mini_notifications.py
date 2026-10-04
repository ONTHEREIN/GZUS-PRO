"""真实路由/数据库验证微信授权隔离；外部微信交换与发送仅替换边界。"""
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx
import pytest
from fastapi.testclient import TestClient

from app import cloud_notifications
from app.config import get_settings
from app.database import (
    BackgroundNotificationProfile, MiniNotificationAccess, MiniNotificationDelivery,
    MiniNotificationPreference, NotificationDelivery, WechatBinding, get_sync_session_factory,
)
from app.main import app
from app.mini_notification_models import WechatApiResult
from app.routes import mini_notifications
from app.sessions import SessionStore, encrypt_device_credentials
from app.demo_data import DemoAcademicClient
from app.wechat_identity import WechatIdentity, encrypt_openid, openid_fingerprint
from app.wechat_notifications import WechatSubscribeClient, deliver_mini_event


@pytest.fixture
def client(monkeypatch):
    app.state.limiter.reset()
    app.state.sessions = SessionStore(ttl_seconds=60, db_factory=get_sync_session_factory)
    session = app.state.sessions.create(DemoAcademicClient(), student_account="20260001")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "test-app")
    monkeypatch.setenv("WECHAT_COURSE_TEMPLATE_ID", "course-template")
    get_settings.cache_clear()
    identity = WechatIdentity(app_id="test-app", openid="test-openid")
    fingerprint = openid_fingerprint(identity)
    with get_sync_session_factory()() as db:
        db.add(WechatBinding(student_id="20260001", openid_fingerprint=fingerprint,
                             encrypted_openid=encrypt_openid(identity.openid), app_id=identity.app_id))
        db.commit()
    monkeypatch.setattr(mini_notifications, "_exchange_or_raise", lambda code: identity)
    value = TestClient(app)
    value.headers.update({"X-Session-Id": session.id})
    yield value
    value.close()


def authorize(client, monkeypatch):
    token = encrypt_device_credentials("20260001", "test-password", "device-test", get_settings().credential_encryption_key)
    monkeypatch.setattr(mini_notifications, "auto_login", lambda payload, request: {"credentialToken": token})
    response = client.post("/mini/notifications/background", json={
        "account": "20260001", "password": "test-password", "code": "test-code", "consent": True})
    assert response.status_code == 200, response.text
    assert response.json()["backgroundAuthorized"] is True
    assert "credentialToken" not in response.text
    assert "test-password" not in response.text
    assert "test-openid" not in response.text


def enable_course(client):
    response = client.put("/mini/notifications/preference", json={"type": "course_reminder", "enabled": True, "code": "code"})
    assert response.status_code == 200, response.text


def subscribe(client, result, request_id):
    return client.post("/mini/notifications/subscription", json={"type": "course_reminder",
        "templateId": "course-template", "requestId": request_id, "result": result, "code": "code"})


def course_setting(response):
    return next(row for row in response.json()["settings"] if row["type"] == "course_reminder")


def test_subscription_identity_idempotency_and_rejection(client, monkeypatch):
    enable_course(client)
    first = subscribe(client, "accept", "receipt-0000000001")
    assert course_setting(first)["credits"] == 1
    assert course_setting(subscribe(client, "accept", "receipt-0000000001"))["credits"] == 1
    assert course_setting(subscribe(client, "reject", "receipt-0000000002"))["credits"] == 0
    monkeypatch.setattr(mini_notifications, "_exchange_or_raise", lambda code: WechatIdentity("test-app", "other-openid"))
    assert subscribe(client, "accept", "receipt-0000000003").status_code == 403


def test_background_and_unbinding_preserve_mobile_profile(client, monkeypatch):
    with get_sync_session_factory()() as db:
        db.add(BackgroundNotificationProfile(student_id="20260001", encrypted_credentials="mobile-credentials",
               credential_fingerprint="mobile-fingerprint", course_reminders_enabled=True))
        db.commit()
    authorize(client, monkeypatch)
    assert client.delete("/mini/notifications/background").status_code == 200
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        assert profile.mobile_enabled is True
        assert profile.encrypted_credentials == "mobile-credentials"
        assert profile.course_reminders_enabled is True
    authorize(client, monkeypatch)
    assert client.delete("/mini/auth/wechat-binding").status_code == 200
    with get_sync_session_factory()() as db:
        assert db.get(MiniNotificationAccess, "20260001") is None
        assert db.query(BackgroundNotificationProfile).one().mobile_enabled is True


def test_mobile_disable_preserves_mini_background(client, monkeypatch):
    authorize(client, monkeypatch)
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        profile.mobile_enabled = True
        db.commit()
    assert client.put("/notifications/background", json={"enabled": False}).status_code == 200
    assert client.get("/mini/notifications/config").json()["backgroundAuthorized"] is True
    assert client.get("/notifications/background").json()["enabled"] is False
    assert client.delete("/mini/notifications/background").status_code == 200
    with get_sync_session_factory()() as db:
        assert db.query(BackgroundNotificationProfile).count() == 0


def test_background_rejects_missing_consent_and_wrong_account(client):
    assert client.post("/mini/notifications/background", json={"account": "20260001", "password": "p", "code": "c", "consent": False}).status_code == 422
    assert client.post("/mini/notifications/background", json={"account": "other", "password": "p", "code": "c", "consent": True}).status_code == 403


def create_course_event():
    cloud_notifications.persist_notification_event("20260001", "course:start:math:2026-10-04:08:50",
        "course_reminder", "即将上课", "10分钟后上课：数学", {
            "courseName": "数学", "location": "A101", "courseTime": (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M")})
    with get_sync_session_factory()() as db:
        row = db.query(NotificationDelivery).one()
        # 模拟移动端已经接受该事件，微信仍必须独立发送。
        row.delivery_status = "delivered"
        db.commit()
        return row.id


@pytest.mark.parametrize("outcome,expected,credits", [("sent", "sent", 0), ("timeout", "unknown", 0), ("reject", "failed", 0), ("invalid", "failed", 1)])
def test_independent_delivery_deduplication_and_unknown_result(client, monkeypatch, outcome, expected, credits):
    authorize(client, monkeypatch)
    enable_course(client)
    assert subscribe(client, "accept", "receipt-0000000001").status_code == 200
    event_id = create_course_event()
    calls = []
    monkeypatch.setattr(WechatSubscribeClient, "token", lambda self: "token")

    def send(self, token, openid, template_id, page, data):
        calls.append(page)
        assert page == "pages/schedule/index"
        assert data["thing5"]["value"] == "数学"
        if outcome == "timeout":
            raise httpx.ReadTimeout("timeout")
        return WechatApiResult(errcode={"sent": 0, "reject": 43101, "invalid": 47003}[outcome], errmsg="result")

    monkeypatch.setattr(WechatSubscribeClient, "send", send)
    deliver_mini_event(event_id)
    deliver_mini_event(event_id)
    assert len(calls) == 1
    with get_sync_session_factory()() as db:
        assert db.query(MiniNotificationDelivery).one().status == expected
        assert db.query(MiniNotificationPreference).one().credits == credits
    response = client.get("/notifications/events")
    assert response.json()["events"][0]["type"] == "course_reminder"
    event_key = response.json()["events"][0]["id"]
    assert client.post(f"/notifications/events/{event_key}/read").status_code == 200
    assert client.get("/notifications/events").json()["events"][0]["readAt"] is not None


def test_expired_and_pre_authorization_events_do_not_consume_grants(client, monkeypatch):
    event_id = create_course_event()
    authorize(client, monkeypatch)
    enable_course(client)
    subscribe(client, "accept", "receipt-0000000001")
    monkeypatch.setattr(WechatSubscribeClient, "token", lambda self: pytest.fail("不能为历史事件获取 token"))
    deliver_mini_event(event_id)
    with get_sync_session_factory()() as db:
        event = db.get(NotificationDelivery, event_id)
        event.created_at = datetime.now(timezone.utc)
        event.delivery_expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
        db.commit()
    deliver_mini_event(event_id)
    with get_sync_session_factory()() as db:
        assert db.query(MiniNotificationPreference).one().credits == 1
        assert db.query(MiniNotificationDelivery).count() == 0


def test_missing_subscription_not_replayed_after_later_grant(client, monkeypatch):
    authorize(client, monkeypatch)
    enable_course(client)
    event_id = create_course_event()
    deliver_mini_event(event_id)
    subscribe(client, "accept", "receipt-0000000001")
    deliver_mini_event(event_id)
    with get_sync_session_factory()() as db:
        assert db.query(MiniNotificationPreference).one().credits == 1
        assert db.query(MiniNotificationDelivery).one().status == "no_subscription"


def test_grade_api_uses_shared_judgement_for_cached_results(client, monkeypatch):
    from app.routes import academic
    rows = [{"courseName": "数学", "score": "59"}, {"courseName": "英语", "score": "60"},
            {"courseName": "体育", "score": "90", "gradeStatus": "不及格"},
            {"courseName": "音乐", "score": "合格", "gradeStatus": "合格"},
            {"courseName": "未知", "score": "优秀"}, {"courseName": "待公布", "score": ""}, {"courseName": "文字不合格", "score": "不合格", "gradeStatus": "不合格", "gradePassed": True}, {"courseName": "非有限数字", "score": "Infinity"}]
    async def cached(*args, **kwargs):
        return rows
    monkeypatch.setattr(academic, "_run_with_cache_fallback", cached)
    response = client.get("/grades")
    assert response.status_code == 200, response.text
    assert [row["gradePassed"] for row in response.json()] == [False, True, False, True, None, None, False, None]


async def test_mini_only_ecard_persists_event_without_mobile_delivery(client, monkeypatch):
    from app import jobs
    from app.database import EcardBinding
    authorize(client, monkeypatch)
    response = client.put("/mini/notifications/preference", json={
        "type": "ecard_reminder", "enabled": True, "code": "code"})
    assert response.status_code == 200
    with get_sync_session_factory()() as db:
        db.add(EcardBinding(student_id="20260001", room_id="CGCOMMON1111|1|A2|932",
                            room_display="A2-932", reminder_enabled=False,
                            reminder_times='["08:00"]'))
        db.commit()

    class Client:
        def balance(self, room_ref, student_id):
            return {"powerBalance": 2, "powerText": "2 度"}

        def close(self):
            pass

    monkeypatch.setattr(jobs, "EcardClient", Client)
    monkeypatch.setattr(jobs, "_active_push_succeeded", lambda *args: pytest.fail("移动端关闭后不能投递"))
    await jobs.run_ecard_reminder_once(app, "08:00")
    await jobs.run_ecard_reminder_once(app, "08:00")
    with get_sync_session_factory()() as db:
        assert db.query(NotificationDelivery).count() == 1
        assert db.query(NotificationDelivery).one().notification_type == "ecard_reminder"
        assert db.query(EcardBinding).one().reminder_enabled is False


def test_course_already_started_does_not_consume_subscription(client, monkeypatch):
    import json
    authorize(client, monkeypatch)
    enable_course(client)
    subscribe(client, "accept", "receipt-0000000001")
    event_id = create_course_event()
    with get_sync_session_factory()() as db:
        event = db.get(NotificationDelivery, event_id)
        extras = json.loads(event.extras_json)
        extras["courseTime"] = (datetime.now(ZoneInfo("Asia/Shanghai")) - timedelta(minutes=1)).strftime("%Y-%m-%d %H:%M")
        event.extras_json = json.dumps(extras)
        db.commit()
    monkeypatch.setattr(WechatSubscribeClient, "token", lambda self: pytest.fail("上课后不能推送上课前提醒"))
    deliver_mini_event(event_id)
    with get_sync_session_factory()() as db:
        assert db.query(MiniNotificationPreference).one().credits == 1
        assert db.query(MiniNotificationDelivery).count() == 0


def test_mini_detection_builds_baseline_then_persists_three_categories(client, monkeypatch):
    authorize(client, monkeypatch)
    for kind in ("grade_update", "exam_reminder", "attendance_update"):
        assert client.put("/mini/notifications/preference", json={
            "type": kind, "enabled": True, "code": "code"}).status_code == 200
    school = DemoAcademicClient()
    exam_time = (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(days=3)).strftime("%Y-%m-%d 09:00-11:00")
    grades = [{"courseName": "数学", "term": "1", "score": "59"}]
    exams = [{"courseName": "数学", "time": exam_time, "location": "A101"}]
    attendance = [{"courseId": "math", "courseName": "数学", "late": 1}]
    monkeypatch.setattr(school, "get_notices", lambda: [])
    monkeypatch.setattr(school, "get_grades", lambda year, term: grades)
    monkeypatch.setattr(school, "get_exams", lambda year, term: exams)
    monkeypatch.setattr(school, "get_attendance", lambda year, term: attendance)
    monkeypatch.setattr(cloud_notifications, "send_push_to_student", lambda *args: pytest.fail("不能向关闭的移动端投递"))
    with get_sync_session_factory()() as db:
        profile = db.query(BackgroundNotificationProfile).one()
        cloud_notifications._poll_profile_once(profile, school, None)
        db.commit()
        assert db.query(NotificationDelivery).count() == 0
        grades[0] = {"courseName": "数学", "term": "1", "score": "60"}
        exams.append({"courseName": "英语", "time": exam_time, "location": "B201"})
        attendance[0] = {"courseId": "math", "courseName": "数学", "late": 2}
        cloud_notifications._poll_profile_once(profile, school, None)
        db.commit()
        cloud_notifications._poll_profile_once(profile, school, None)
        db.commit()
        assert sorted(row.notification_type for row in db.query(NotificationDelivery).all()) == [
            "attendance_update", "exam_reminder", "grade_update"]


def test_revocation_during_token_request_prevents_delivery(client, monkeypatch):
    from app import database
    authorize(client, monkeypatch)
    enable_course(client)
    subscribe(client, "accept", "receipt-0000000001")
    event_id = create_course_event()

    def token(self):
        assert database.get_sync_engine().pool.checkedout() == 0
        mini_notifications.revoke_mini_access("20260001")
        return "token"

    monkeypatch.setattr(WechatSubscribeClient, "token", token)
    monkeypatch.setattr(WechatSubscribeClient, "send", lambda *args: pytest.fail("授权已撤销不能发送"))
    deliver_mini_event(event_id)
    with get_sync_session_factory()() as db:
        assert db.query(MiniNotificationDelivery).count() == 0
