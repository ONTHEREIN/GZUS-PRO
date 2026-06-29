from __future__ import annotations

import os
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, Float, Integer, String, Text, create_engine, event, inspect, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import get_settings


class Base(DeclarativeBase):
    pass


class EhallSession(Base):
    __tablename__ = "ehall_sessions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    account = Column(String(100), nullable=False, index=True)
    cookies_json = Column(Text, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    expires_at = Column(DateTime, nullable=False, index=True)
    last_used_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


class EcardBinding(Base):
    __tablename__ = "ecard_bindings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    student_id = Column(String(100), nullable=False, unique=True, index=True)
    room_id = Column(String(200), nullable=False)
    room_display = Column(String(200), nullable=False)
    reminder_enabled = Column(Boolean, default=True, nullable=False)
    low_power_threshold = Column(Float, default=30.0, nullable=False)
    last_summary_json = Column(Text, nullable=True)
    last_checked_at = Column(DateTime, nullable=True)
    last_reminded_date = Column(String(20), nullable=True)
    reminder_times = Column(Text, default='["08:00"]', nullable=False)
    reminder_items = Column(Text, default='["power","cold_water","hot_water"]', nullable=False)
    low_cold_water_threshold = Column(Float, default=5.0, nullable=False)
    low_hot_water_threshold = Column(Float, default=10.0, nullable=False)
    last_reminded_times = Column(Text, default='{}', nullable=True)
    # 热水余额缓存（独立于 last_summary_json，用于超时 fallback）
    hot_water_balance_cache = Column(Float, nullable=True)
    hot_water_cache_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class PushRegistration(Base):
    __tablename__ = "push_registrations"

    id = Column(Integer, primary_key=True, autoincrement=True)
    student_id = Column(String(100), nullable=False, index=True)
    registration_id = Column(String(300), nullable=False, unique=True)
    platform = Column(String(50), default="android")
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class WebPushSubscription(Base):
    __tablename__ = "web_push_subscriptions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    student_id = Column(String(100), nullable=False, index=True)
    endpoint = Column(String(500), nullable=False, unique=True)
    p256dh = Column(String(300), nullable=False)
    auth = Column(String(100), nullable=False)
    expiration_time = Column(DateTime, nullable=True)
    user_agent = Column(String(500), nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class DataCache(Base):
    __tablename__ = "data_cache"

    id = Column(Integer, primary_key=True, autoincrement=True)
    cache_key = Column(String(500), nullable=False, unique=True, index=True)
    student_id = Column(String(100), nullable=False, index=True)
    resource = Column(String(100), nullable=False, index=True)
    params_hash = Column(String(64), nullable=False, default="")
    response_json = Column(Text, nullable=False)
    cached_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


class StaffMember(Base):
    __tablename__ = "staff_members"

    userid = Column(String(100), primary_key=True)
    cn_name = Column(String(100), nullable=False, index=True)
    job_title = Column(String(100), nullable=True, index=True)
    folder_name = Column(String(300), nullable=True, index=True)
    wf_or_unid = Column(String(100), nullable=True)
    wf_last_modified = Column(String(100), nullable=True)
    sort_number = Column(Integer, nullable=True)
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class AppSessionModel(Base):
    """Persistent session storage for serverless deployments.

    Stores session metadata and cookie strings needed to reconstruct
    SchoolSdkClient / EhallClient after a cold start.  The live client
    objects are rebuilt on demand via login_with_cookies().
    """

    __tablename__ = "app_sessions"

    id = Column(String(64), primary_key=True)
    student_name = Column(String(100), nullable=True)
    student_account = Column(String(100), nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), nullable=False, index=True)
    last_active_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), nullable=False)
    push_registration_id = Column(String(300), nullable=True)
    push_platform = Column(String(50), default="android", nullable=False)
    jwxt_cookies = Column(Text, nullable=True)
    ehall_cookies = Column(Text, nullable=True)
    ehall_auth_token = Column(Text, nullable=True)
    encrypted_credentials = Column(Text, nullable=True)
    revoked_at = Column(DateTime, nullable=True, index=True)
    revoked_reason = Column(String(100), nullable=True)


_engine = None
_async_engine = None
_session_factory = None
_async_session_factory = None
_db_initialized = False


def _resolve_sync_url(raw_url: str) -> str:
    if raw_url.startswith("postgres://"):
        return raw_url.replace("postgres://", "postgresql://", 1)
    if raw_url.startswith("sqlite+aiosqlite://"):
        return raw_url.replace("sqlite+aiosqlite://", "sqlite://", 1)
    if raw_url.startswith("postgresql+asyncpg://"):
        return raw_url.replace("postgresql+asyncpg://", "postgresql://", 1)
    return raw_url


def _resolve_async_url(raw_url: str) -> str:
    if raw_url.startswith("postgres://"):
        return raw_url.replace("postgres://", "postgresql+asyncpg://", 1)
    if raw_url.startswith("postgresql://"):
        return raw_url.replace("postgresql://", "postgresql+asyncpg://", 1)
    if raw_url.startswith("sqlite://") and "aiosqlite" not in raw_url:
        return raw_url.replace("sqlite://", "sqlite+aiosqlite://", 1)
    return raw_url


def _validate_database_url(raw_url: str) -> None:
    if not raw_url:
        raise RuntimeError("DATABASE_URL must be set to a PostgreSQL connection string. "
                           "Example: postgresql://user:pass@127.0.0.1:5432/dbname")
    if raw_url.startswith(("postgres://", "postgresql://", "postgresql+asyncpg://")):
        return
    if raw_url.startswith(("sqlite://", "sqlite+aiosqlite://")):
        if ":memory:" in raw_url:
            return
        raise RuntimeError(
            "SQLite file databases are not supported because they can contain local user data. "
            "Use PostgreSQL for deployment or sqlite:///:memory: for tests."
        )
    raise RuntimeError(
        "DATABASE_URL must be a PostgreSQL or SQLite connection string. "
        f"Got: {raw_url[:50]}..."
    )


def get_sync_engine():
    global _engine
    if _engine is None:
        settings = get_settings()
        _validate_database_url(settings.database_url)
        database_url = _resolve_sync_url(settings.database_url)
        if database_url.startswith("postgresql"):
            _engine = create_engine(
                database_url,
                pool_size=settings.db_pool_size,
                max_overflow=settings.db_max_overflow,
                pool_recycle=settings.db_pool_recycle,
                pool_pre_ping=True,
                pool_timeout=settings.db_pool_timeout,
            )
        elif ":memory:" in database_url:
            _engine = create_engine(
                database_url,
                poolclass=StaticPool,
                connect_args={"check_same_thread": False},
            )
        else:
            _engine = create_engine(
                database_url,
                connect_args={"check_same_thread": False},
                pool_pre_ping=True,
            )
    return _engine


def get_async_engine():
    global _async_engine
    if _async_engine is None:
        settings = get_settings()
        _validate_database_url(settings.database_url)
        database_url = _resolve_async_url(settings.database_url)
        if database_url.startswith("postgresql"):
            _async_engine = create_async_engine(
                database_url,
                pool_size=settings.db_pool_size,
                max_overflow=settings.db_max_overflow,
                pool_recycle=settings.db_pool_recycle,
                pool_pre_ping=True,
                pool_timeout=settings.db_pool_timeout,
            )
        elif ":memory:" in database_url:
            _async_engine = create_async_engine(
                database_url,
                poolclass=StaticPool,
                connect_args={"check_same_thread": False},
            )
        else:
            _async_engine = create_async_engine(
                database_url,
                connect_args={"check_same_thread": False},
                pool_pre_ping=True,
            )
    return _async_engine


def get_sync_session_factory() -> sessionmaker[Session]:
    global _session_factory
    if _session_factory is None:
        init_db()
        _session_factory = sessionmaker(bind=get_sync_engine(), expire_on_commit=False)
    return _session_factory


def get_async_session_factory() -> async_sessionmaker[AsyncSession]:
    global _async_session_factory
    if _async_session_factory is None:
        _async_session_factory = async_sessionmaker(
            bind=get_async_engine(), expire_on_commit=False
        )
    return _async_session_factory


def _is_sqlite(engine) -> bool:
    return "sqlite" in str(engine.url)


def _apply_sqlite_pragmas(engine) -> None:
    @event.listens_for(engine, "connect")
    def _set_sqlite_pragmas(dbapi_connection, _connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.execute("PRAGMA cache_size=-64000")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.close()

    with engine.connect() as conn:
        conn.execute(text("PRAGMA journal_mode=WAL"))
        conn.execute(text("PRAGMA synchronous=NORMAL"))
        conn.execute(text("PRAGMA cache_size=-64000"))
        conn.execute(text("PRAGMA busy_timeout=5000"))
        conn.commit()


def init_db():
    global _db_initialized
    if _db_initialized:
        return
    settings = get_settings()
    if os.environ.get("VERCEL") == "1" and not settings.debug:
        _db_initialized = True
        return
    engine = get_sync_engine()
    Base.metadata.create_all(engine)

    # Lightweight migration: add columns that exist in the model but might not
    # exist in the database yet (e.g., added after initial deployment).
    _ensure_columns(engine, "app_sessions", {
        "student_account": "VARCHAR(100)",
        "revoked_at": "TIMESTAMP",
        "revoked_reason": "VARCHAR(100)",
    })
    _ensure_columns(engine, "ecard_bindings", {
        "hot_water_balance_cache": "FLOAT",
        "hot_water_cache_at": "TIMESTAMP",
    })

    if _is_sqlite(engine):
        _apply_sqlite_pragmas(engine)

    _db_initialized = True


def _ensure_columns(engine, table: str, columns: dict[str, str]) -> None:
    """Add columns to an existing table if they don't already exist.

    This is a lightweight, idempotent migration helper for serverless
    deployments where a full migration framework is overkill.  Each
    call is safe to run on every cold start.
    """
    import logging
    _logger = logging.getLogger(__name__)
    try:
        existing_columns = {column["name"] for column in inspect(engine).get_columns(table)}
        missing_columns = {
            col_name: col_type
            for col_name, col_type in columns.items()
            if col_name not in existing_columns
        }
        if not missing_columns:
            return

        with engine.connect() as conn:
            if not _is_sqlite(engine):
                conn.exec_driver_sql("SET lock_timeout = '2s'")
                conn.exec_driver_sql("SET statement_timeout = '10s'")
            for col_name, col_type in missing_columns.items():
                try:
                    conn.exec_driver_sql(
                        f"ALTER TABLE {table} ADD COLUMN {col_name} {col_type}"
                    )
                    conn.commit()
                    _logger.info("Migrated: added column %s to %s", col_name, table)
                except Exception:
                    # Column likely already exists — safe to ignore
                    conn.rollback()
    except Exception:
        # Table might not exist yet (fresh DB created by create_all above)
        pass


def reset_engine():
    global _engine, _async_engine, _session_factory, _async_session_factory, _db_initialized
    _engine = None
    _async_engine = None
    _session_factory = None
    _async_session_factory = None
    _db_initialized = False
