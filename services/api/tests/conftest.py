import pytest

from app.config import get_settings


@pytest.fixture(autouse=True)
def _reset_db(monkeypatch):
    """每个测试使用独立内存 SQLite，测试间完全隔离。"""
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    get_settings.cache_clear()
    from app import database
    from app.cache_service import reset_cache_factory

    database.reset_engine()
    reset_cache_factory()
    yield
    database.reset_engine()
    reset_cache_factory()
    get_settings.cache_clear()
