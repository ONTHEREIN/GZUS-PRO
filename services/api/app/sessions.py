from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from secrets import token_urlsafe
from typing import Protocol


class AcademicClient(Protocol):
    def get_info(self) -> dict: ...

    def get_student_photo(self) -> str | None: ...

    def get_schedule(self, year: str | None, term: str | None) -> list[dict]: ...

    def get_exams(self, year: str | None, term: str | None) -> list[dict]: ...

    def get_grades(self, year: str | None, term: str | None) -> list[dict]: ...

    def get_attendance(self, year: str | None, term: str | None) -> list[dict]: ...

    def get_credits(self) -> list[dict]: ...

    def logout(self) -> None: ...


@dataclass
class AppSession:
    id: str
    client: AcademicClient
    student_name: str | None
    expires_at: datetime


class SessionStore:
    def __init__(self, ttl_seconds: int) -> None:
        self._ttl = timedelta(seconds=ttl_seconds)
        self._sessions: dict[str, AppSession] = {}

    def create(self, client: AcademicClient, student_name: str | None = None) -> AppSession:
        session_id = token_urlsafe(32)
        session = AppSession(
            id=session_id,
            client=client,
            student_name=student_name,
            expires_at=datetime.now(UTC) + self._ttl,
        )
        self._sessions[session_id] = session
        return session

    def get(self, session_id: str) -> AppSession | None:
        session = self._sessions.get(session_id)
        if session is None:
            return None
        if session.expires_at <= datetime.now(UTC):
            self.delete(session_id)
            return None
        session.expires_at = datetime.now(UTC) + self._ttl
        return session

    def delete(self, session_id: str) -> None:
        session = self._sessions.pop(session_id, None)
        if session is not None:
            session.client.logout()
