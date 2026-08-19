import os

import pytest

from app.config import get_settings

# 模块级覆盖：pytest 收集阶段（autouse fixture 尚未执行）就可能有测试模块
# import app 代码并触发 get_settings()（如 app.rsa_keys 的模块级实例化）。
# 若本地 services/api/.env 是 DEBUG=false 的生产配置，收集期校验会误伤，
# 这里在 conftest 加载时先把测试环境变量写进 os.environ（优先级高于 .env），
# 与下方 autouse fixture 的取值保持一致。
os.environ["DEBUG"] = "true"
os.environ["DATABASE_URL"] = "sqlite:///:memory:"
os.environ["CREDENTIAL_ENCRYPTION_KEY"] = "test-credential-key"
os.environ["PUBLIC_API_BASE_URL"] = "https://api.example.test"
os.environ["FRONTEND_BASE_URL"] = "https://app.example.test"


@pytest.fixture(autouse=True)
def _reset_db(monkeypatch):
    """每个测试使用独立内存 SQLite，测试间完全隔离。"""
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("CREDENTIAL_ENCRYPTION_KEY", "test-credential-key")
    monkeypatch.setenv("PUBLIC_API_BASE_URL", "https://api.example.test")
    monkeypatch.setenv("FRONTEND_BASE_URL", "https://app.example.test")
    get_settings.cache_clear()
    from app import database
    from app.cache_service import reset_cache_factory

    database.reset_engine()
    reset_cache_factory()
    yield
    database.reset_engine()
    reset_cache_factory()
    get_settings.cache_clear()
