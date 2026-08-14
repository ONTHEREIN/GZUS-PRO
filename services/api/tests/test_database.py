import pytest
from sqlalchemy import event, inspect
from sqlalchemy.exc import NoSuchTableError

from app import database
from app.config import get_settings


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

    assert str(engine.url) == "sqlite:///:memory:"


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


def test_ensure_columns_raises_when_table_is_missing():
    database.init_db()
    engine = database.get_sync_engine()

    with pytest.raises(NoSuchTableError):
        database._ensure_columns(engine, "missing_table", {"label": "VARCHAR(20)"})


def test_init_db_skips_schema_work_on_vercel(monkeypatch):
    monkeypatch.setenv("VERCEL", "1")
    monkeypatch.setenv("DEBUG", "false")
    get_settings.cache_clear()
    database.reset_engine()

    database.init_db()

    assert database._db_initialized is True
    assert database._engine is None
