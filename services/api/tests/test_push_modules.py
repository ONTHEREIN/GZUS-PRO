import app.jobs as jobs
from app.ws import ConnectionManager
from app.jobs import (
    NoticeCache,
    changed_grade_items,
    ecard_progress_current,
    grade_snapshot,
    run_exam_reminder_once,
    run_grade_update_once,
    run_notice_poller_once,
)


class TestConnectionManager:
    def test_connect_and_disconnect(self):
        manager = ConnectionManager()
        assert len(manager.active) == 0
        manager.active["sid1"] = None
        assert "sid1" in manager.active
        manager.disconnect("sid1")
        assert "sid1" not in manager.active

    def test_disconnect_nonexistent(self):
        manager = ConnectionManager()
        manager.disconnect("nonexistent")

    async def test_send_to_nonexistent_session(self):
        manager = ConnectionManager()
        await manager.send_to_session("nonexistent", {"type": "test"})
        messages = manager.drain("nonexistent")
        assert len(messages) == 1
        assert messages[0]["type"] == "test"
        assert "id" in messages[0]

    def test_enqueue_and_drain(self):
        manager = ConnectionManager()
        manager.enqueue("sid1", {"type": "new_notice", "url": "/notice"})
        messages = manager.drain("sid1")
        assert messages[0]["extras"] == {"type": "new_notice", "url": "/notice"}
        assert manager.drain("sid1") == []

    def test_enqueue_preserves_live_update_fields_in_extras(self):
        manager = ConnectionManager()
        manager.enqueue(
            "sid1",
            {
                "id": "exam_reminder:sid1:math",
                "type": "exam_reminder",
                "courseName": "高等数学",
                "liveUpdate": True,
                "style": "progress",
                "endTime": 1780966800000,
                "shortCriticalText": "考试",
                "progressMax": 100,
                "progressCurrent": 0,
            },
        )

        message = manager.drain("sid1")[0]

        assert message["id"] == "exam_reminder:sid1:math"
        assert message["extras"]["type"] == "exam_reminder"
        assert message["extras"]["courseName"] == "高等数学"
        assert message["extras"]["liveUpdate"] is True
        assert message["extras"]["style"] == "progress"
        assert message["extras"]["endTime"] == 1780966800000
        assert message["extras"]["progressMax"] == 100
        assert message["extras"]["progressCurrent"] == 0


class TestLiveUpdateHelpers:
    def test_grade_snapshot_detects_new_and_changed_scores(self):
        previous_items = [
            {"term": "2025-2", "courseName": "高等数学", "score": "90", "gradePoint": "4.0"}
        ]
        current_items = [
            {"term": "2025-2", "courseName": "高等数学", "score": "92", "gradePoint": "4.0"},
            {"term": "2025-2", "courseName": "移动应用开发", "score": "95", "gradePoint": "4.3"},
        ]

        changed = changed_grade_items(current_items, grade_snapshot(previous_items))

        assert [item["courseName"] for item in changed] == ["高等数学", "移动应用开发"]

    def test_ecard_progress_uses_lowest_enabled_balance(self):
        summary = {
            "powerBalance": 15,
            "coldWaterBalance": 2,
            "hotWaterBalance": 10,
        }

        assert ecard_progress_current(summary, "power", 30, 10, 20, ["power"]) == 50
        assert ecard_progress_current(
            summary,
            "daily",
            30,
            10,
            20,
            ["power", "cold_water", "hot_water"],
        ) == 20


class TestNoticeCache:
    def test_get_empty(self):
        cache = NoticeCache()
        assert cache.get_cached_titles("sid1") == set()

    def test_update_and_get(self):
        cache = NoticeCache()
        cache.update("sid1", {"通知1", "通知2"})
        assert cache.get_cached_titles("sid1") == {"通知1", "通知2"}

    def test_remove(self):
        cache = NoticeCache()
        cache.update("sid1", {"通知1"})
        cache.remove("sid1")
        assert cache.get_cached_titles("sid1") == set()

    def test_remove_nonexistent(self):
        cache = NoticeCache()
        cache.remove("nonexistent")


class FakeNoticeClient:
    def __init__(self):
        self.items = [{"title": "旧通知", "url": "/old"}]

    def get_notices(self):
        return list(self.items)

    def get_info(self):
        return {}


class FakeNoticeSession:
    id = "sid1"

    def __init__(self):
        self.client = FakeNoticeClient()


class FakeWsManager:
    def __init__(self):
        self.sent = []

    async def send_to_session(self, session_id, message):
        self.sent.append((session_id, message))


class FakeState:
    pass


class FakeApp:
    def __init__(self):
        session = FakeNoticeSession()
        sessions = type("Sessions", (), {"_sessions": {session.id: session}})()
        self.state = FakeState()
        self.state.sessions = sessions
        self.state.ws_manager = FakeWsManager()
        self.state.notice_cache = NoticeCache()
        self.session = session


class TestNoticePoller:
    async def test_notice_poller_sends_only_new_items(self):
        app = FakeApp()
        await run_notice_poller_once(app)
        assert app.state.ws_manager.sent == []

        app.session.client.items.insert(0, {"title": "新通知", "url": "/new"})
        await run_notice_poller_once(app)

        assert len(app.state.ws_manager.sent) == 1
        session_id, message = app.state.ws_manager.sent[0]
        assert session_id == "sid1"
        assert message["type"] == "new_notice"
        assert message["body"] == "新通知"

    async def test_notice_poller_retries_when_persistent_push_fails(self, monkeypatch):
        app = FakeApp()
        app.session.client.get_info = lambda: {"studentId": "20260001"}
        attempts = []

        def deliver(*_args, **_kwargs):
            attempts.append(True)
            return len(attempts) > 1

        monkeypatch.setattr(jobs, "_active_push_succeeded", deliver)
        await run_notice_poller_once(app)

        app.session.client.items.insert(0, {"title": "新通知", "url": "/new"})
        await run_notice_poller_once(app)
        assert len(app.state.ws_manager.sent) == 1
        assert "|新通知|/new" not in app.state.notice_cache.get_cached_titles("sid1")

        await run_notice_poller_once(app)
        assert len(app.state.ws_manager.sent) == 2
        assert "|新通知|/new" in app.state.notice_cache.get_cached_titles("sid1")

    async def test_notice_poller_ignores_garbled_items(self):
        app = FakeApp()
        await run_notice_poller_once(app)

        app.session.client.items.insert(0, {"title": "æ–°é€šçŸ¥", "url": "/bad"})
        await run_notice_poller_once(app)

        assert app.state.ws_manager.sent == []


class _RetryGradeClient:
    def __init__(self):
        self.grades = [{"term": "2026-1", "courseName": "高等数学", "score": "90"}]

    def get_info(self):
        return {"studentId": "20260001"}

    def get_grades(self, _start, _term):
        return list(self.grades)


def _academic_app(client):
    session = type("Session", (), {"id": "sid1", "client": client})()
    sessions = type("Sessions", (), {"_sessions": {session.id: session}})()
    app = type("App", (), {})()
    app.state = type("State", (), {})()
    app.state.sessions = sessions
    app.state.ws_manager = FakeWsManager()
    return app


async def test_grade_update_retries_after_push_failure(monkeypatch):
    client = _RetryGradeClient()
    app = _academic_app(client)
    attempts = []

    def deliver(*_args, **_kwargs):
        attempts.append(True)
        return len(attempts) > 1

    monkeypatch.setattr(jobs, "_active_push_succeeded", deliver)
    await run_grade_update_once(app)
    client.grades[0]["score"] = "92"
    await run_grade_update_once(app)
    await run_grade_update_once(app)

    assert len(attempts) == 2
    assert len(app.state.ws_manager.sent) == 2


async def test_exam_reminder_retries_after_push_failure(monkeypatch):
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo

    exam_time = datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(hours=1)
    client = type(
        "ExamClient",
        (),
        {
            "get_info": lambda self: {"studentId": "20260001"},
            "get_exams": lambda self, _start, _term: [{
                "courseName": "高等数学",
                "time": exam_time.strftime("%Y-%m-%d %H:%M-11:00"),
                "location": "A101",
            }],
        },
    )()
    app = _academic_app(client)
    attempts = []

    def deliver(*_args, **_kwargs):
        attempts.append(True)
        return len(attempts) > 1

    monkeypatch.setattr(jobs, "_active_push_succeeded", deliver)
    await run_exam_reminder_once(app)
    await run_exam_reminder_once(app)

    assert len(attempts) == 2
    assert len(app.state.ws_manager.sent) == 2
