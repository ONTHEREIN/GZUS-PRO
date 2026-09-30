from datetime import datetime, timezone
from threading import Event, Thread

import pytest
from sqlalchemy import event, inspect
from sqlalchemy.exc import NoSuchTableError

from app import database
from app.config import get_settings
from app.database import (
    AppSessionModel,
    DataCache,
    IosLiveActivityToken,
    IosPushToken,
    WebPushSubscription,
    get_sync_session_factory,
)


def test_init_db_backfills_push_credential_ownership():
    database.init_db()
    fingerprint = "a" * 64
    with get_sync_session_factory()() as db:
        db.add(AppSessionModel(id="legacy-session", credential_fingerprint=fingerprint))
        db.add(WebPushSubscription(
            student_id="20240001", session_id="legacy-session",
            endpoint="https://fcm.googleapis.com/legacy", p256dh="key", auth="auth",
        ))
        db.add(IosPushToken(
            student_id="20240001", session_id="legacy-session",
            device_token="a" * 64, environment="production",
        ))
        db.add(IosLiveActivityToken(
            student_id="20240001", session_id="legacy-session",
            token_type="start", token="b" * 64, environment="production",
        ))
        db.add(WebPushSubscription(
            student_id="20240001", session_id="already-expired",
            endpoint="https://fcm.googleapis.com/orphan", p256dh="key", auth="auth",
        ))
        db.commit()

    database._db_initialized = False
    database.init_db()

    with get_sync_session_factory()() as db:
        assert db.query(WebPushSubscription).count() == 1
        assert db.query(WebPushSubscription).one().credential_fingerprint == fingerprint
        assert db.query(IosPushToken).one().credential_fingerprint == fingerprint
        assert db.query(IosLiveActivityToken).one().credential_fingerprint == fingerprint


def test_init_db_removes_legacy_plaintext_ecard_token():
    database.init_db()
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(DataCache(
            cache_key="ecard_global_token", student_id="", resource="ecard",
            response_json='{"token":"legacy-secret"}',
        ))
        db.commit()

    database._db_initialized = False
    database.init_db()

    with factory() as db:
        assert db.query(DataCache).filter_by(cache_key="ecard_global_token").count() == 0


def test_requires_database_url(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "")
    get_settings.cache_clear()
    database.reset_engine()

    with pytest.raises(RuntimeError, match="DATABASE_URL must be set"):
        database.get_sync_engine()


def test_rejects_file_sqlite_database_url(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:///./gzus_pro.db")
    get_settings.cache_clear()
    database.reset_engine()

    with pytest.raises(RuntimeError, match="SQLite file databases are not supported"):
        database.get_sync_engine()


def test_allows_memory_sqlite_for_tests(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    get_settings.cache_clear()
    database.reset_engine()

    engine = database.get_sync_engine()

    assert engine.url.query["mode"] == "memory"
    assert engine.url.query["cache"] == "shared"
    with engine.begin() as writer:
        writer.exec_driver_sql("CREATE TABLE shared_memory_probe (value INTEGER NOT NULL)")
        writer.exec_driver_sql("INSERT INTO shared_memory_probe (value) VALUES (42)")
    with engine.connect() as first, engine.connect() as second:
        assert first.connection.driver_connection is not second.connection.driver_connection
        assert second.exec_driver_sql("SELECT value FROM shared_memory_probe").scalar_one() == 42

    waiting = Event()
    acquired = Event()

    def open_other_thread_connection() -> None:
        waiting.set()
        with engine.connect():
            acquired.set()

    with engine.connect():
        worker = Thread(target=open_other_thread_connection)
        worker.start()
        assert waiting.wait(1)
        assert not acquired.wait(0.05)
    assert acquired.wait(1)
    worker.join(timeout=1)
    assert not worker.is_alive()


def test_ensure_columns_skips_existing_columns():
    database.init_db()
    engine = database.get_sync_engine()
    statements: list[str] = []

    @event.listens_for(engine, "before_cursor_execute")
    def _capture_statement(_conn, _cursor, statement, _parameters, _context, _executemany):
        statements.append(statement)

    try:
        database._ensure_columns(engine, "app_sessions", {"student_account": "VARCHAR(100)"})
    finally:
        event.remove(engine, "before_cursor_execute", _capture_statement)

    assert not any(statement.lstrip().upper().startswith("ALTER TABLE") for statement in statements)


def test_ensure_columns_adds_missing_column():
    database.init_db()
    engine = database.get_sync_engine()
    with engine.begin() as connection:
        connection.exec_driver_sql("CREATE TABLE migration_probe (id INTEGER PRIMARY KEY)")

    database._ensure_columns(engine, "migration_probe", {"label": "VARCHAR(20)"})

    column_names = {column["name"] for column in inspect(engine).get_columns("migration_probe")}
    assert column_names == {"id", "label"}


def test_session_compatibility_migration_adds_persistent_session_columns():
    database.init_db()
    engine = database.get_sync_engine()
    with engine.begin() as connection:
        connection.exec_driver_sql("CREATE TABLE legacy_app_sessions (id VARCHAR(64) PRIMARY KEY)")

    database._ensure_columns(engine, "legacy_app_sessions", database._APP_SESSION_COMPAT_COLUMNS)

    column_names = {
        column["name"] for column in inspect(engine).get_columns("legacy_app_sessions")
    }
    assert set(database._APP_SESSION_COMPAT_COLUMNS).issubset(column_names)


def test_ensure_columns_raises_when_table_is_missing():
    database.init_db()
    engine = database.get_sync_engine()

    with pytest.raises(NoSuchTableError):
        database._ensure_columns(engine, "missing_table", {"label": "VARCHAR(20)"})


def test_init_db_initializes_schema_in_production(monkeypatch):
    monkeypatch.setenv("DEBUG", "true")
    get_settings.cache_clear()
    database.reset_engine()

    database.init_db()

    assert database._db_initialized is True
    assert database._engine is not None


def test_init_db_removes_legacy_activity_tokens_without_expiry():
    database.init_db()
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(AppSessionModel(id="current-session"))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            session_id="current-session",
            token_type="activity",
            token="a" * 64,
            environment="production",
            activity_id="legacy:activity",
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001",
            session_id="current-session",
            token_type="activity",
            token="b" * 64,
            environment="production",
            activity_id="new:activity",
            expires_at=datetime.now(timezone.utc),
        ))
        db.commit()

    database._db_initialized = False
    database.init_db()

    with factory() as db:
        assert db.query(IosLiveActivityToken).filter_by(token="a" * 64).count() == 0
        assert db.query(IosLiveActivityToken).filter_by(token="b" * 64).count() == 1


def test_init_db_removes_push_targets_without_session_owner():
    database.init_db()
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(WebPushSubscription(
            student_id="20260001", endpoint="https://push.example.test/legacy",
            p256dh="key", auth="auth",
        ))
        db.add(IosPushToken(
            student_id="20260001", device_token="a" * 64, environment="production",
        ))
        db.add(IosLiveActivityToken(
            student_id="20260001", token_type="start", token="b" * 64,
            environment="production",
        ))
        db.commit()

    database._db_initialized = False
    database.init_db()

    with factory() as db:
        assert db.query(WebPushSubscription).count() == 0
        assert db.query(IosPushToken).count() == 0
        assert db.query(IosLiveActivityToken).count() == 0
