from __future__ import annotations

import asyncio
import base64
import hashlib
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Protocol

from cryptography.fernet import Fernet
from sqlalchemy.orm import Session as DbSession

logger = logging.getLogger(__name__)


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


def _rebuild_school_client(jwxt_cookies: str) -> Any:
    """Rebuild a SchoolSdkClient from stored cookies."""
    from app.config import get_settings
    from app.school_client import SchoolSdkClient

    settings = get_settings()
    client = SchoolSdkClient(
        settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
    )
    client.login_with_cookies(jwxt_cookies, "")
    return client


def _rebuild_ehall_client(ehall_cookies: str | None, ehall_auth_token: str | None) -> Any:
    """Rebuild an EhallClient from stored cookies."""
    from app.ehall_client import EhallClient
    from app.config import get_settings

    settings = get_settings()
    return EhallClient(
        settings.ehall_base_url,
        ehall_cookies or "",
        auth_token=ehall_auth_token,
        timeout_seconds=settings.request_timeout_seconds,
    )


class SessionStore:
    """Persistent session store backed by PostgreSQL.

    Designed for serverless deployments (Vercel) where in-memory state is
    lost on every cold start.  Session metadata and JWXT/ehall cookies are
    stored in the database; live client objects are rebuilt on demand.

    Usage:
        store = SessionStore(ttl_seconds=7200, db_factory=get_sync_session_factory)
        session = store.create(client, student_name)
        ...
        restored = store.get(session_id)  # rebuilds clients from DB cookies
    """

    def __init__(
        self,
        ttl_seconds: int,
        db_factory: Callable[[], DbSession] | None = None,
    ) -> None:
        self._ttl = timedelta(seconds=ttl_seconds)
        self._db_factory = db_factory
        self._cleanup_task: asyncio.Task | None = None

    def _get_db(self) -> DbSession:
        if self._db_factory is None:
            from app.database import get_sync_session_factory

            self._db_factory = get_sync_session_factory()
        return self._db_factory()

    # ------------------------------------------------------------------
    # Public API (compatible with old memory-based interface)
    # ------------------------------------------------------------------

    def create(
        self,
        client: Any,
        student_name: str | None = None,
        ehall_client: Any | None = None,
        encrypted_credentials: str | None = None,
    ) -> AppSession:
        from app.database import AppSessionModel

        # Extract cookies from live client objects
        jwxt_cookies = ""
        if client is not None:
            try:
                jwxt_cookies = client.get_jwxt_cookies_string()
            except Exception:
                logger.warning("Failed to extract JWXT cookies from client", exc_info=True)

        ehall_cookies = ""
        ehall_auth_token = ""
        if ehall_client is not None:
            try:
                ehall_cookies = ehall_client.cookie_header
            except Exception:
                pass
            try:
                ehall_auth_token = ehall_client._auth_token or ""
            except Exception:
                pass

        session = AppSession(
            id=uuid.uuid4().hex,
            client=client,
            student_name=student_name,
            ehall_client=ehall_client,
            encrypted_credentials=encrypted_credentials,
        )

        db = self._get_db()
        try:
            row = AppSessionModel(
                id=session.id,
                student_name=student_name,
                created_at=session.created_at.replace(tzinfo=timezone.utc) if session.created_at.tzinfo is None else session.created_at,
                last_active_at=session.last_active_at.replace(tzinfo=timezone.utc) if session.last_active_at.tzinfo is None else session.last_active_at,
                jwxt_cookies=jwxt_cookies or None,
                ehall_cookies=ehall_cookies or None,
                ehall_auth_token=ehall_auth_token or None,
                encrypted_credentials=encrypted_credentials,
            )
            db.add(row)
            db.commit()
            logger.debug("Session %s created in DB (jwxt_cookies=%d chars)", session.id[:8], len(jwxt_cookies))
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

        return session

    def get(self, session_id: str, *, touch: bool = True) -> AppSession | None:
        from app.database import AppSessionModel

        db = self._get_db()
        try:
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is None:
                return None

            # Absolute TTL check
            now_utc = datetime.now(timezone.utc)
            if row.created_at.tzinfo is None:
                created_utc = row.created_at.replace(tzinfo=timezone.utc)
            else:
                created_utc = row.created_at
            if now_utc - created_utc > self._ttl:
                logger.debug("Session %s expired (TTL=%ds)", session_id[:8], int(self._ttl.total_seconds()))
                db.delete(row)
                db.commit()
                return None

            # Rebuild client objects from stored cookies
            client = None
            ehall_client = None
            if row.jwxt_cookies:
                try:
                    client = _rebuild_school_client(row.jwxt_cookies)
                except Exception:
                    logger.warning(
                        "Failed to rebuild SchoolSdkClient for session %s, cookies may be stale",
                        session_id[:8],
                        exc_info=True,
                    )
                    return None

            if row.ehall_cookies or row.ehall_auth_token:
                try:
                    ehall_client = _rebuild_ehall_client(row.ehall_cookies, row.ehall_auth_token)
                except Exception:
                    logger.warning("Failed to rebuild EhallClient for session %s", session_id[:8])

            # Build runtime session object
            last_active = row.last_active_at
            if last_active.tzinfo is not None:
                last_active = last_active.replace(tzinfo=None)

            session = AppSession(
                id=row.id,
                client=client,
                student_name=row.student_name,
                ehall_client=ehall_client,
                created_at=created_utc.replace(tzinfo=None),
                last_active_at=last_active,
                push_registration_id=row.push_registration_id,
                push_platform=row.push_platform or "android",
                encrypted_credentials=row.encrypted_credentials,
            )

            if touch:
                self.touch(session_id)

            return session
        finally:
            db.close()

    def touch(self, session_id: str) -> None:
        from app.database import AppSessionModel

        db = self._get_db()
        try:
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is not None:
                row.last_active_at = datetime.now(timezone.utc)
                db.commit()
        except Exception:
            db.rollback()
        finally:
            db.close()

    def update(self, session_id: str, **fields: Any) -> None:
        """Persist mutable session fields (e.g. push_registration_id) to DB."""
        from app.database import AppSessionModel

        allowed = {"push_registration_id", "push_platform", "encrypted_credentials", "student_name"}
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return

        db = self._get_db()
        try:
            db.query(AppSessionModel).filter(AppSessionModel.id == session_id).update(
                updates, synchronize_session=False
            )
            db.commit()
        except Exception:
            db.rollback()
        finally:
            db.close()

    def remove(self, session_id: str) -> None:
        from app.database import AppSessionModel

        db = self._get_db()
        try:
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is not None:
                db.delete(row)
                db.commit()
        except Exception:
            db.rollback()
        finally:
            db.close()

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    async def start_cleanup_task(self) -> None:
        async def _cleanup_loop() -> None:
            while True:
                await asyncio.sleep(300)
                try:
                    self._purge_expired()
                except Exception:
                    logger.warning("Session cleanup failed", exc_info=True)

        self._cleanup_task = asyncio.create_task(_cleanup_loop())

    def stop_cleanup_task(self) -> None:
        if self._cleanup_task is not None:
            self._cleanup_task.cancel()
            self._cleanup_task = None

    def _purge_expired(self) -> None:
        from app.database import AppSessionModel

        cutoff = datetime.now(timezone.utc) - self._ttl
        db = self._get_db()
        try:
            deleted = (
                db.query(AppSessionModel)
                .filter(AppSessionModel.created_at < cutoff)
                .delete(synchronize_session=False)
            )
            db.commit()
            if deleted:
                logger.info("Purged %d expired sessions", deleted)
        except Exception:
            db.rollback()
        finally:
            db.close()
