from __future__ import annotations

import logging
import uuid
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)


class ConnectionManager:
    def __init__(self) -> None:
        self.active: dict[str, WebSocket] = {}
        self.pending: dict[str, list[dict]] = {}

    async def connect(self, websocket: WebSocket, session_id: str) -> None:
        await websocket.accept()
        self.active[session_id] = websocket

    def disconnect(self, session_id: str) -> None:
        self.active.pop(session_id, None)

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
        queued = self.enqueue(session_id, message)
        websocket = self.active.get(session_id)
        if websocket is None:
            return
        try:
            await websocket.send_json(queued)
        except Exception:
            self.disconnect(session_id)

    async def broadcast(self, message: dict) -> None:
        disconnected = []
        for session_id, websocket in self.active.items():
            queued = self.enqueue(session_id, message)
            try:
                await websocket.send_json(queued)
            except Exception:
                disconnected.append(session_id)
        for session_id in disconnected:
            self.disconnect(session_id)


ws_router = APIRouter()


def _message_extras(message: dict) -> dict:
    extras = {}
    for key in (
        "type",
        "url",
        "courseName",
        "studentId",
        "liveUpdate",
        "style",
        "endTime",
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
    await websocket.accept()
    if not sessionId:
        await websocket.close(code=4001, reason="会话无效")
        return
    sessions = websocket.app.state.sessions
    session = sessions.get(sessionId)
    if session is None:
        await websocket.close(code=4001, reason="会话已过期")
        return
    manager: ConnectionManager = websocket.app.state.ws_manager
    manager.active[session.id] = websocket
    try:
        while True:
            try:
                await websocket.receive_text()
            except WebSocketDisconnect:
                break
    finally:
        manager.disconnect(session.id)
