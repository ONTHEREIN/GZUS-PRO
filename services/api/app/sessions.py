from __future__ import annotations

import asyncio
import base64
import hashlib
import logging
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Protocol

from cryptography.fernet import Fernet
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session as DbSession

logger = logging.getLogger(__name__)

_DB_CONNECTION_ATTEMPTS = 3
_DB_RETRY_BASE_DELAY_SECONDS = 0.3


class SessionStoreUnavailableError(RuntimeError):
    """会话持久层暂时不可用。"""


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
    revoked_at: datetime | None = None
    revoked_reason: str | None = None
    student_account: str | None = None


def _get_fernet(key: str) -> Fernet:
    """Create a Fernet instance from a config key string."""
    raw = hashlib.sha256(key.encode("utf-8")).digest()
    return Fernet(base64.urlsafe_b64encode(raw))


def student_id_of(session: "AppSession") -> str:
    """获取学号：优先使用会话中已持久化的 student_account，
    仅在缺失时回退到 client.get_info()（含学生照片下载的 JWXT 往返）。"""
    account = getattr(session, "student_account", None)
    if account:
        return str(account)
    try:
        info = session.client.get_info()
    except Exception:
        return ""
    return str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")


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


def _rebuild_school_client(
    jwxt_cookies: str,
    validate_cookies: bool = False,
    session_id: str | None = None,
    account: str | None = None,
) -> Any:
    """Rebuild a SchoolSdkClient from stored cookies.

    By default does NOT validate cookies against JWXT (validate_cookies=False)
    because cookies obtained from the Cloudflare Worker edge are IP-bounded
    and cannot be verified from Vercel's IP.  The real validation happens on
    the first actual API call; the caller handles AuthenticationError gracefully.
    """
    from app.config import get_settings
    from app.school_client import SchoolSdkClient

    settings = get_settings()
    client = SchoolSdkClient(
        settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
        session_id=session_id,
        worker_proxy_origin=settings.jwxt_worker_proxy_origin or None,
    )
    client.login_with_cookies(jwxt_cookies, account or "", validate=validate_cookies)
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
        self._sessions: dict[str, AppSession] = {}
        self._session_checked_at: dict[str, datetime] = {}
        self._last_touch_at: dict[str, datetime] = {}
        self._memory_cache_ttl = timedelta(seconds=30)
        self._touch_write_interval = timedelta(seconds=60)
        self._legacy_credentials_cleared = False

    def _get_db(self) -> DbSession:
        from sqlalchemy.orm import sessionmaker as SessionMaker

        if self._db_factory is None:
            from app.database import get_sync_session_factory

            self._db_factory = get_sync_session_factory()

        # Normalize: _db_factory must be a sessionmaker instance.
        # If it's a plain callable (e.g. the get_sync_session_factory function
        # passed as db_factory parameter), resolve it once to get the actual
        # sessionmaker.  We must use isinstance — sessionmaker is also callable,
        # so a callable check alone would mis-identify it as a factory function.
        if not isinstance(self._db_factory, SessionMaker) and callable(self._db_factory):
            self._db_factory = self._db_factory()

        return self._db_factory()

    def _open_db(self, operation: str, session_id: str) -> DbSession:
        """获取数据库会话，短暂故障时重试，失败后保留原始异常。"""
        last_error: Exception | None = None
        for attempt in range(1, _DB_CONNECTION_ATTEMPTS + 1):
            try:
                return self._get_db()
            except Exception as exc:
                last_error = exc
                logger.warning(
                    "Failed to acquire session database connection",
                    extra={
                        "operation": operation,
                        "session_id": session_id[:8],
                        "attempt": attempt,
                        "max_attempts": _DB_CONNECTION_ATTEMPTS,
                    },
                    exc_info=attempt == _DB_CONNECTION_ATTEMPTS,
                )
                if attempt < _DB_CONNECTION_ATTEMPTS:
                    time.sleep(_DB_RETRY_BASE_DELAY_SECONDS * attempt)

        if last_error is None:
            raise RuntimeError("数据库连接重试未执行")
        raise SessionStoreUnavailableError(
            f"会话数据库不可用：operation={operation}, session={session_id[:8]}"
        ) from last_error

    def _clear_legacy_credentials(self, db: DbSession) -> None:
        """清除旧版本遗留但已不再使用的可解密登录凭据。"""
        if self._legacy_credentials_cleared:
            return
        from app.database import AppSessionModel

        cleared = (
            db.query(AppSessionModel)
            .filter(AppSessionModel.encrypted_credentials.is_not(None))
            .update({"encrypted_credentials": None}, synchronize_session=False)
        )
        db.commit()
        self._legacy_credentials_cleared = True
        if cleared:
            logger.info(
                "Cleared legacy persisted login credentials",
                extra={"cleared_count": cleared},
            )

    @staticmethod
    def _persistence_error(
        operation: str,
        session_id: str,
        error: SQLAlchemyError,
    ) -> SessionStoreUnavailableError:
        return SessionStoreUnavailableError(
            f"会话数据库操作失败：operation={operation}, session={session_id[:8]}, "
            f"error={type(error).__name__}"
        )

    # ------------------------------------------------------------------
    # Public API (compatible with old memory-based interface)
    # ------------------------------------------------------------------

    def create(
        self,
        client: Any,
        student_name: str | None = None,
        ehall_client: Any | None = None,
        student_account: str | None = None,
    ) -> AppSession:
        from app.database import AppSessionModel

        # Extract cookies from live client objects
        jwxt_cookies = ""
        resolved_student_account = (student_account or "").strip() or None
        if client is not None:
            try:
                jwxt_cookies = client.get_jwxt_cookies_string()
            except Exception:
                logger.warning("Failed to extract JWXT cookies from client", exc_info=True)
            if resolved_student_account is None:
                try:
                    resolved_student_account = getattr(client, "_account", None) or None
                    if resolved_student_account == "":
                        resolved_student_account = None
                except Exception:
                    pass

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
            student_account=resolved_student_account,
        )

        db = self._open_db("create", session.id)

        try:
            self._clear_legacy_credentials(db)
            if resolved_student_account:
                for existing in self._sessions.values():
                    if (
                        existing.student_account == resolved_student_account
                        and existing.revoked_at is None
                    ):
                        existing.revoked_at = datetime.now(timezone.utc).replace(tzinfo=None)
                        existing.revoked_reason = "single_device_login"
                revoked_at = datetime.now(timezone.utc)
                revoked = (
                    db.query(AppSessionModel)
                    .filter(AppSessionModel.student_account == resolved_student_account)
                    .filter(AppSessionModel.revoked_at.is_(None))
                    .update(
                        {
                            "revoked_at": revoked_at,
                            "revoked_reason": "single_device_login",
                        },
                        synchronize_session=False,
                    )
                )
                if revoked:
                    logger.info(
                        "Revoked %d existing sessions for account %s",
                        revoked,
                        resolved_student_account,
                    )
            row = AppSessionModel(
                id=session.id,
                student_name=student_name,
                student_account=resolved_student_account,
                created_at=session.created_at.replace(tzinfo=timezone.utc) if session.created_at.tzinfo is None else session.created_at,
                last_active_at=session.last_active_at.replace(tzinfo=timezone.utc) if session.last_active_at.tzinfo is None else session.last_active_at,
                jwxt_cookies=jwxt_cookies or None,
                ehall_cookies=ehall_cookies or None,
                ehall_auth_token=ehall_auth_token or None,
            )
            db.add(row)
            db.commit()
            self._sessions[session.id] = session
            self._session_checked_at[session.id] = datetime.now(timezone.utc).replace(tzinfo=None)
            self._last_touch_at[session.id] = session.last_active_at.replace(tzinfo=None)
            logger.debug("Session %s created in DB (jwxt_cookies=%d chars)", session.id[:8], len(jwxt_cookies))
        except SQLAlchemyError as exc:
            db.rollback()
            raise self._persistence_error("create", session.id, exc) from exc
        finally:
            db.close()

        return session

    def get(
        self,
        session_id: str,
        *,
        touch: bool = True,
        fresh: bool = False,
    ) -> AppSession | None:
        from app.database import AppSessionModel

        now_naive = datetime.now(timezone.utc).replace(tzinfo=None)
        cached = self._sessions.get(session_id)
        checked_at = self._session_checked_at.get(session_id)
        if (
            not fresh
            and
            cached is not None
            and cached.revoked_at is None
            and checked_at is not None
            and now_naive - checked_at < self._memory_cache_ttl
            and now_naive - cached.last_active_at < self._ttl
        ):
            if touch:
                self.touch(session_id)
            return cached

        db = self._open_db("get", session_id)

        try:
            self._clear_legacy_credentials(db)
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is None:
                # Neon PostgreSQL may have a slight read-after-write delay
                # after a session is created on a different serverless
                # instance.  Retry up to 3 times with increasing backoff.
                for attempt in range(3):
                    delay = 0.3 * (attempt + 1)
                    logger.debug(
                        "Session %s not found on attempt %d/3, retrying after %.1fs",
                        session_id[:8],
                        attempt + 1,
                        delay,
                    )
                    time.sleep(delay)
                    db.commit()  # refresh transaction snapshot
                    row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
                    if row is not None:
                        break
                if row is None:
                    logger.warning(
                        "Session %s not found after %d retries (read-after-write lag?)",
                        session_id[:8],
                        3,
                    )
                    return None

            # Sliding TTL check based on last_active_at.
            # Active sessions stay alive; idle sessions expire after TTL.
            now_utc = datetime.now(timezone.utc)
            last_active_dt = row.last_active_at
            if last_active_dt.tzinfo is None:
                last_active_dt = last_active_dt.replace(tzinfo=timezone.utc)
            if now_utc - last_active_dt > self._ttl:
                idle_secs = int((now_utc - last_active_dt).total_seconds())
                logger.debug(
                    "Session %s expired (sliding TTL=%ds, idle=%ds)",
                    session_id[:8],
                    int(self._ttl.total_seconds()),
                    idle_secs,
                )
                db.delete(row)
                db.commit()
                return None

            revoked_at = getattr(row, "revoked_at", None)
            if revoked_at is not None:
                if revoked_at.tzinfo is not None:
                    revoked_at = revoked_at.replace(tzinfo=None)
                cached = self._sessions.get(row.id)
                if cached is not None:
                    cached.revoked_at = revoked_at
                    cached.revoked_reason = row.revoked_reason or "single_device_login"
                    return cached
                return AppSession(
                    id=row.id,
                    client=None,
                    student_name=row.student_name,
                    created_at=row.created_at.replace(tzinfo=None)
                    if row.created_at.tzinfo is not None
                    else row.created_at,
                    last_active_at=row.last_active_at.replace(tzinfo=None)
                    if row.last_active_at.tzinfo is not None
                    else row.last_active_at,
                    push_registration_id=row.push_registration_id,
                    push_platform=row.push_platform or "android",
                    revoked_at=revoked_at,
                    revoked_reason=row.revoked_reason or "single_device_login",
                    student_account=row.student_account,
                )

            # Compute created_utc for AppSession construction below
            if row.created_at.tzinfo is None:
                created_utc = row.created_at.replace(tzinfo=timezone.utc)
            else:
                created_utc = row.created_at

            cached = self._sessions.get(row.id)
            if cached is not None:
                cached.student_name = row.student_name
                cached.last_active_at = row.last_active_at.replace(tzinfo=None)
                if row.created_at.tzinfo is not None:
                    cached.created_at = row.created_at.replace(tzinfo=None)
                else:
                    cached.created_at = row.created_at
                cached.push_registration_id = row.push_registration_id
                cached.push_platform = row.push_platform or "android"
                cached.student_account = row.student_account
                self._session_checked_at[session_id] = datetime.now(timezone.utc).replace(tzinfo=None)
                if touch:
                    self.touch(session_id)
                return cached

            # Rebuild client objects from stored cookies.
            # If DB rebuild fails (stale cookies), leave client=None so
            # _inject_worker_cookies() can attempt recovery with fresh
            # cookies injected by the Cloudflare Worker edge.
            client = None
            ehall_client = None
            if row.jwxt_cookies:
                try:
                    client = _rebuild_school_client(
                        row.jwxt_cookies,
                        session_id=session_id,
                        account=getattr(row, "student_account", None) or None,
                    )
                except Exception:
                    logger.warning(
                        "Failed to rebuild SchoolSdkClient from DB cookies for session %s — "
                        "client will be None, recovery possible if Worker injects fresh cookies",
                        session_id[:8],
                        exc_info=True,
                    )
                    # DO NOT return None — allow caller to attempt recovery
                    # via Worker-injected cookies in _inject_worker_cookies().

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
                student_account=row.student_account,
            )

            self._sessions[session.id] = session
            self._session_checked_at[session.id] = datetime.now(timezone.utc).replace(tzinfo=None)
            if touch:
                self.touch(session_id)

            return session
        except SQLAlchemyError as exc:
            logger.error(
                "Failed to retrieve session from database",
                extra={"operation": "get", "session_id": session_id[:8]},
                exc_info=True,
            )
            raise self._persistence_error("get", session_id, exc) from exc
        finally:
            db.close()

    def touch(self, session_id: str) -> None:
        from app.database import AppSessionModel

        now = datetime.now(timezone.utc)
        now_naive = now.replace(tzinfo=None)
        cached = self._sessions.get(session_id)
        if cached is not None:
            cached.last_active_at = now_naive
        last_touch = self._last_touch_at.get(session_id)
        if last_touch is not None and now_naive - last_touch < self._touch_write_interval:
            return

        db = self._open_db("touch", session_id)
        try:
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is not None:
                row.last_active_at = now
                db.commit()
                self._last_touch_at[session_id] = now_naive
                cached = self._sessions.get(session_id)
                if cached is not None:
                    cached.last_active_at = row.last_active_at.replace(tzinfo=None)
        except SQLAlchemyError as exc:
            db.rollback()
            raise self._persistence_error("touch", session_id, exc) from exc
        finally:
            db.close()

    def update(self, session_id: str, **fields: Any) -> None:
        """Persist mutable session fields (e.g. push_registration_id) to DB."""
        from app.database import AppSessionModel

        allowed = {
            "push_registration_id", "push_platform",
            "student_name",
            "jwxt_cookies", "ehall_cookies", "ehall_auth_token",
        }
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return

        db = self._open_db("update", session_id)
        try:
            db.query(AppSessionModel).filter(AppSessionModel.id == session_id).update(
                updates, synchronize_session=False
            )
            db.commit()
        except SQLAlchemyError as exc:
            db.rollback()
            raise self._persistence_error("update", session_id, exc) from exc
        finally:
            db.close()

    def remove(self, session_id: str) -> None:
        from app.database import AppSessionModel

        db = self._open_db("remove", session_id)
        try:
            row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
            if row is not None:
                db.delete(row)
                db.commit()
            self._sessions.pop(session_id, None)
            self._session_checked_at.pop(session_id, None)
            self._last_touch_at.pop(session_id, None)
        except SQLAlchemyError as exc:
            db.rollback()
            raise self._persistence_error("remove", session_id, exc) from exc
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
                .filter(AppSessionModel.last_active_at < cutoff)
                .delete(synchronize_session=False)
            )
            db.commit()
            if deleted:
                cutoff_naive = cutoff.replace(tzinfo=None)
                for session_id, session in list(self._sessions.items()):
                    if session.last_active_at < cutoff_naive:
                        self._sessions.pop(session_id, None)
                        self._session_checked_at.pop(session_id, None)
                        self._last_touch_at.pop(session_id, None)
                logger.info("Purged %d expired sessions", deleted)
        except SQLAlchemyError:
            db.rollback()
            raise
        finally:
            db.close()
