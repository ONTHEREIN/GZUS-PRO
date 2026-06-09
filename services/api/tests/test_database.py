import pytest

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
