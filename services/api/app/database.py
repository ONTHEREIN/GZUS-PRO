from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, Float, Integer, String, Text, create_engine
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

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


_engine = None
_async_engine = None
_session_factory = None
_async_session_factory = None


def get_sync_engine():
    global _engine
    if _engine is None:
        settings = get_settings()
        database_url = settings.database_url.replace("sqlite+aiosqlite://", "sqlite://", 1)
        _engine = create_engine(database_url)
    return _engine


def get_async_engine():
    global _async_engine
    if _async_engine is None:
        settings = get_settings()
        _async_engine = create_async_engine(settings.database_url)
    return _async_engine


def get_sync_session_factory() -> sessionmaker[Session]:
    global _session_factory
    if _session_factory is None:
        _session_factory = sessionmaker(bind=get_sync_engine(), expire_on_commit=False)
    return _session_factory


def get_async_session_factory() -> async_sessionmaker[AsyncSession]:
    global _async_session_factory
    if _async_session_factory is None:
        _async_session_factory = async_sessionmaker(
            bind=get_async_engine(), expire_on_commit=False
        )
    return _async_session_factory


def init_db():
    engine = get_sync_engine()
    Base.metadata.create_all(engine)
