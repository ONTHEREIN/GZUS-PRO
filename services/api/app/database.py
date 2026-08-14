from __future__ import annotations

import os
from collections.abc import Mapping
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, Float, Integer, String, Text, create_engine, event, inspect, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import get_settings


class Base(DeclarativeBase):
    pass


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
    # 管理后台标记：登录时查 admin_users 表写入，require_admin 依赖据此鉴权。
    is_admin = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), nullable=False, index=True)
    last_active_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), nullable=False)
    push_registration_id = Column(String(300), nullable=True)
    push_platform = Column(String(50), default="android", nullable=False)
    jwxt_cookies = Column(Text, nullable=True)
    ehall_cookies = Column(Text, nullable=True)
    ehall_auth_token = Column(Text, nullable=True)
    # 仅保留旧数据库结构兼容；SessionStore 会清空该列且不再写入登录凭据。
    encrypted_credentials = Column(Text, nullable=True)
    revoked_at = Column(DateTime, nullable=True, index=True)
    revoked_reason = Column(String(100), nullable=True)


class UserSettings(Base):
    """按用户绑定的偏好设置（云端同步，登录后拉取）。

    目前存放课表偏好：各学期第一周开始日期、自动周次、开学引导完成标记。
    first_weeks_json 为 JSON 对象，键为 "{year}-{term}"（如 "2026-1"），
    值为 yyyy-MM-dd 字符串（已归一化为周一）。
    """

    __tablename__ = "user_settings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    student_id = Column(String(100), nullable=False, unique=True, index=True)
    first_weeks_json = Column(Text, nullable=True)
    auto_week = Column(Boolean, default=True, nullable=False)
    onboarding_completed = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class AdminUser(Base):
    """管理后台白名单：学号在表中的在校学生即管理员（复用 CAS SSO 登录）。

    role 取值 "owner"（可管理管理员/踢任意会话）或 "admin"（可查看统计/踢学生会话）。
    """

    __tablename__ = "admin_users"

    student_id = Column(String(100), primary_key=True)
    role = Column(String(20), default="admin", nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class AdminAuditLog(Base):
    """管理后台敏感操作审计日志（踢下线/增删管理员/清缓存）。"""

    __tablename__ = "admin_audit_log"

    id = Column(Integer, primary_key=True, autoincrement=True)
    operator_id = Column(String(100), nullable=False, index=True)
    action = Column(String(50), nullable=False)
    target_type = Column(String(50), nullable=True)
    target_id = Column(String(100), nullable=True)
    detail = Column(Text, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)


class WxArticle(Base):
    """公众号文章（从微信公开「合集」接口同步，标题/封面/简介/链接）。

    source 标记数据来源（album=合集同步 / paste=管理员粘贴链接）；
    hidden 为隐藏状态，隐藏后不再出现在通知列表（但不物理删除）。
    """

    __tablename__ = "wx_articles"

    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(500), nullable=False)
    summary = Column(Text, nullable=True)
    cover_url = Column(String(1000), nullable=True)
    article_url = Column(String(1000), nullable=False, unique=True, index=True)
    author = Column(String(200), nullable=True)
    publish_time = Column(String(50), nullable=True)
    source = Column(String(20), default="album", nullable=False)
    hidden = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class WechatSyncState(Base):
    """公众号同步状态：记录最近一次同步时间，供惰性同步判断过期。"""

    __tablename__ = "wechat_sync_state"

    id = Column(Integer, primary_key=True, autoincrement=True)
    key = Column(String(50), nullable=False, unique=True)
    last_synced_at = Column(DateTime, nullable=True)
    last_error = Column(Text, nullable=True)
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class AdminNotice(Base):
    """管理员上传的通知/校历（图片为主，存 Postgres bytea）。

    is_pinned 置顶（通知列表优先展示）；published 为发布开关。
    image_data 存单张图片（≤3MB），经 /admin/notices/{id}/image 二进制返回。
    """

    __tablename__ = "admin_notices"

    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(300), nullable=False)
    description = Column(Text, nullable=True)
    image_data = Column(Text, nullable=True)  # base64 编码的图片数据（≤3MB）
    image_mime = Column(String(100), nullable=True)
    is_pinned = Column(Boolean, default=False, nullable=False)
    published = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


_engine = None
_session_factory = None
_db_initialized = False


def _resolve_sync_url(raw_url: str) -> str:
    if raw_url.startswith("postgres://"):
        return raw_url.replace("postgres://", "postgresql://", 1)
    if raw_url.startswith("sqlite+aiosqlite://"):
        return raw_url.replace("sqlite+aiosqlite://", "sqlite://", 1)
    if raw_url.startswith("postgresql+asyncpg://"):
        return raw_url.replace("postgresql+asyncpg://", "postgresql://", 1)
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


def get_sync_session_factory() -> sessionmaker[Session]:
    global _session_factory
    if _session_factory is None:
        init_db()
        _session_factory = sessionmaker(bind=get_sync_engine(), expire_on_commit=False)
    return _session_factory


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
        "is_admin": "BOOLEAN",
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


def _ensure_columns(engine: Engine, table: str, columns: Mapping[str, str]) -> None:
    """Add columns to an existing table if they don't already exist.

    This is a lightweight, idempotent migration helper for serverless
    deployments where a full migration framework is overkill.  Each
    call is safe to run on every cold start.
    """
    existing_columns = {column["name"] for column in inspect(engine).get_columns(table)}
    missing_columns = {
        column_name: column_type
        for column_name, column_type in columns.items()
        if column_name not in existing_columns
    }
    if not missing_columns:
        return

    with engine.begin() as connection:
        is_sqlite = _is_sqlite(engine)
        if not is_sqlite:
            connection.exec_driver_sql("SET LOCAL lock_timeout = '2s'")
            connection.exec_driver_sql("SET LOCAL statement_timeout = '10s'")
        for column_name, column_type in missing_columns.items():
            if is_sqlite:
                statement = f"ALTER TABLE {table} ADD COLUMN {column_name} {column_type}"
            else:
                statement = (
                    f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS "
                    f"{column_name} {column_type}"
                )
            connection.exec_driver_sql(statement)


def reset_engine():
    global _engine, _session_factory, _db_initialized
    _engine = None
    _session_factory = None
    _db_initialized = False
