from __future__ import annotations

import logging
import uuid
from collections import deque
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)


class ConnectionManager:
    def __init__(self) -> None:
        self.active: dict[str, WebSocket] = {}
        self.pending: dict[str, list[dict]] = {}
        self.revoked: set[str] = set()
        self._recent_revocations: deque[str] = deque()

    async def connect(self, websocket: WebSocket, session_id: str) -> bool:
        if session_id in self.revoked:
            await websocket.close(code=4001, reason="会话已失效")
            return False
        await websocket.accept()
        previous = self.active.get(session_id)
        self.active[session_id] = websocket
        if previous is not None:
            try:
                await previous.close(code=4002, reason="已有新的连接")
            except (OSError, RuntimeError, WebSocketDisconnect) as exc:
                logger.warning(
                    "websocket_replace_close_failed",
                    extra={"session_id_prefix": session_id[:8], "error": repr(exc)},
                )
        return True

    def disconnect(self, session_id: str, websocket: WebSocket) -> None:
        if self.active.get(session_id) is websocket:
            self.active.pop(session_id, None)

    async def revoke(self, session_id: str) -> None:
        if session_id not in self.revoked:
            self.revoked.add(session_id)
            self._recent_revocations.append(session_id)
            if len(self._recent_revocations) > 1024:
                self.revoked.remove(self._recent_revocations.popleft())
        websocket = self.active.pop(session_id, None)
        self.pending.pop(session_id, None)
        if websocket is not None:
            try:
                await websocket.close(code=4001, reason="会话已失效")
            except (OSError, RuntimeError, WebSocketDisconnect) as exc:
                logger.warning(
                    "websocket_close_failed",
                    extra={"session_id_prefix": session_id[:8], "error": repr(exc)},
                )

    def enqueue(self, session_id: str, message: dict) -> dict:
        queued = dict(message)
        queued.setdefault("id", uuid.uuid4().hex)
        extras = dict(queued.get("extras") or {})
        extras.update(_message_extras(queued))
        queued["extras"] = extras
        items = self.pending.setdefault(session_id, [])
        items.append(queued)
        if len(items) > 100:
            del items[:-100]
        return queued

    def drain(self, session_id: str) -> list[dict]:
        return self.pending.pop(session_id, [])

    async def send_to_session(self, session_id: str, message: dict) -> None:
        if session_id in self.revoked:
            return
        queued = self.enqueue(session_id, message)
        websocket = self.active.get(session_id)
        if websocket is None:
            return
        try:
            await websocket.send_json(queued)
        except Exception:
            self.disconnect(session_id, websocket)

    async def broadcast(self, message: dict) -> None:
        disconnected = []
        for session_id, websocket in list(self.active.items()):
            if session_id in self.revoked or self.active.get(session_id) is not websocket:
                continue
            queued = self.enqueue(session_id, message)
            try:
                await websocket.send_json(queued)
            except Exception:
                disconnected.append((session_id, websocket))
        for session_id, websocket in disconnected:
            self.disconnect(session_id, websocket)


ws_router = APIRouter()


def _message_extras(message: dict) -> dict:
    extras = {}
    for key in (
        "type",
        "url",
        "courseName",
        "studentId",
        "eventKey",
        "liveUpdate",
        "liveEvent",
        "ongoing",
        "style",
        "startTime",
        "startTimeMillis",
        "endTime",
        "endTimeMillis",
        "shortCriticalText",
        "progressStartTime",
        "progressMax",
        "progressCurrent",
        "progress",
    ):
        if message.get(key) is not None:
            extras[key] = message[key]
    return extras


@ws_router.websocket("/ws/notifications")
async def websocket_notifications(websocket: WebSocket, sessionId: str | None = None) -> None:
    if not sessionId:
        await websocket.close(code=4001, reason="会话无效")
        return
    sessions = websocket.app.state.sessions
    session = sessions.get(sessionId, touch=False)
    if session is None:
        logger.warning("websocket_notifications: session %s not found", sessionId[:8])
        await websocket.close(code=4001, reason="会话已过期")
        return
    if session.revoked_at is not None:
        logger.info(
            "websocket_notifications: session %s revoked (reason=%s)",
            session.id[:8],
            session.revoked_reason,
        )
        await websocket.close(code=4001, reason="当前设备已被管理员下线，请重新验证登录")
        return
    manager: ConnectionManager = websocket.app.state.ws_manager
    if not await manager.connect(websocket, session.id):
        return
    sessions.touch(session.id)
    try:
        while True:
            try:
                await websocket.receive_text()
            except WebSocketDisconnect:
                break
    finally:
        manager.disconnect(session.id, websocket)
