import pytest

from app.push import send_push, send_push_to_all
from app.ws import ConnectionManager
from app.jobs import NoticeCache, run_notice_poller_once


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


class TestSendPush:
    async def test_send_push_no_credentials(self):
        result = await send_push(["rid1"], "title", "alert")
        assert result is False

    async def test_send_push_empty_ids(self):
        result = await send_push([], "title", "alert")
        assert result is False

    async def test_send_push_to_all_empty(self):
        result = await send_push_to_all([], "title", "alert")
        assert result is False
