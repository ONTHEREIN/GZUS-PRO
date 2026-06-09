from __future__ import annotations

import asyncio
import base64
import hashlib
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Protocol

from cryptography.fernet import Fernet


class AcademicClient(Protocol):
    def get_info(self) -> dict:
        ...

    def get_schedule(self, year: str | None, term: str | None) -> list[dict]:
        ...

    def get_exams(self, year: str | None, term: str | None) -> list[dict]:
        ...

    def get_grades(self, year: str | None, term: str | None) -> list[dict]:
        ...

    def get_attendance(self, year: str | None, term: str | None) -> list[dict]:
        ...

    def get_credits(self) -> list[dict]:
        ...

    def get_notices(self) -> list[dict]:
        ...

    def get_notice_detail(self, url: str) -> dict:
        ...

    def logout(self) -> None:
        ...


@dataclass
class AppSession:
    id: str
    client: Any
    student_name: str | None = None
    ehall_client: Any | None = None
    created_at: datetime = field(default_factory=datetime.now)
    last_active_at: datetime = field(default_factory=datetime.now)
    push_registration_id: str | None = None
    push_platform: str = "android"
    encrypted_credentials: str | None = None


def _get_fernet(key: str) -> Fernet:
    """Create a Fernet instance from a config key string."""
    raw = hashlib.sha256(key.encode("utf-8")).digest()
    return Fernet(base64.urlsafe_b64encode(raw))


def encrypt_credentials(account: str, password: str, key: str) -> str:
    """Encrypt account:password into a single token."""
    f = _get_fernet(key)
    return f.encrypt(f"{account}:{password}".encode("utf-8")).decode("ascii")


def decrypt_credentials(token: str, key: str, ttl_seconds: int | None = None) -> tuple[str, str]:
    """Decrypt a token back into (account, password)."""
    f = _get_fernet(key)
    plain = f.decrypt(token.encode("ascii"), ttl=ttl_seconds).decode("utf-8")
    account, password = plain.split(":", 1)
    return account, password


class SessionStore:
    def __init__(self, ttl_seconds: int) -> None:
        self._sessions: dict[str, AppSession] = {}
        self._ttl = timedelta(seconds=ttl_seconds)
        self._cleanup_task: asyncio.Task | None = None

    def create(
        self,
        client: Any,
        student_name: str | None = None,
        ehall_client: Any | None = None,
    ) -> AppSession:
        session = AppSession(
            id=uuid.uuid4().hex,
            client=client,
            student_name=student_name,
            ehall_client=ehall_client,
        )
        self._sessions[session.id] = session
        return session

    def get(self, session_id: str, *, touch: bool = True) -> AppSession | None:
        session = self._sessions.get(session_id)
        if session is None:
            return None
        if datetime.now() - session.created_at > self._ttl:
            self._remove(session.id)
            return None
        if touch:
            self.touch(session.id)
        return session

    def touch(self, session_id: str) -> None:
        session = self._sessions.get(session_id)
        if session is not None:
            session.last_active_at = datetime.now()

    def remove(self, session_id: str) -> None:
        self._remove(session_id)

    def _remove(self, session_id: str) -> None:
        session = self._sessions.pop(session_id, None)
        if session is not None:
            if session.ehall_client is not None:
                try:
                    close = getattr(session.ehall_client, "close", None)
                    if close:
                        close()
                except Exception:
                    pass
            if session.client is not None:
                try:
                    session.client.logout()
                except Exception:
                    pass

    async def start_cleanup_task(self) -> None:
        async def cleanup():
            while True:
                await asyncio.sleep(300)
                now = datetime.now()
                expired = [
                    sid for sid, s in self._sessions.items()
                    if now - s.created_at > self._ttl
                ]
                for sid in expired:
                    self._remove(sid)

        self._cleanup_task = asyncio.create_task(cleanup())

    def stop_cleanup_task(self) -> None:
        if self._cleanup_task is not None:
            self._cleanup_task.cancel()
            self._cleanup_task = None
