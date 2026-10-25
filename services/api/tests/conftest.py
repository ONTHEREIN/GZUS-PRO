import os
from urllib.parse import urlparse

import pytest

from app.config import get_settings

def _test_database_url() -> str:
    url = os.environ.get("GZUS_TEST_POSTGRES_URL")
    if url is None:
        return "sqlite:///:memory:"
    parsed = urlparse(url)
    if parsed.scheme != "postgresql" or not parsed.path.startswith("/gzus_device_acceptance_"):
        raise ValueError("隔离 PostgreSQL 测试只允许 gzus_device_acceptance_ 前缀数据库")
    return url


def _test_rsa_private_key_pem() -> str:
    """测试专用 RSA 私钥。

    DEBUG=false 的用例会触发 config.py 的生产启动校验，要求 RSA_PRIVATE_KEY_PEM
    非空。测试不能依赖本地 services/api/.env 提供该值（CI 没有 .env），这里统一
    生成合法 PEM，保证本地与 CI 行为一致。
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


_TEST_RSA_PRIVATE_KEY_PEM = _test_rsa_private_key_pem()


# 模块级覆盖：pytest 收集阶段（autouse fixture 尚未执行）就可能有测试模块
# import app 代码并触发 get_settings()（如 app.rsa_keys 的模块级实例化）。
# 若本地 services/api/.env 是 DEBUG=false 的生产配置，收集期校验会误伤，
# 这里在 conftest 加载时先把测试环境变量写进 os.environ（优先级高于 .env），
# 与下方 autouse fixture 的取值保持一致。
os.environ["DEBUG"] = "true"
os.environ["DATABASE_URL"] = _test_database_url()
os.environ["CREDENTIAL_ENCRYPTION_KEY"] = "test-credential-key"
os.environ["PUBLIC_API_BASE_URL"] = "https://api.example.test"
os.environ["FRONTEND_BASE_URL"] = "https://app.example.test"
os.environ["EHALL_SERVICE_URL"] = "https://ehall.gzus.edu.cn/shiro-cas"
os.environ["ECARD_VERIFY_TLS"] = "true"
os.environ["RSA_PRIVATE_KEY_PEM"] = _TEST_RSA_PRIVATE_KEY_PEM


@pytest.fixture(autouse=True)
def _reset_db(monkeypatch):
    """每个测试使用独立内存 SQLite，测试间完全隔离。"""
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DATABASE_URL", _test_database_url())
    monkeypatch.setenv("CREDENTIAL_ENCRYPTION_KEY", "test-credential-key")
    monkeypatch.setenv("PUBLIC_API_BASE_URL", "https://api.example.test")
    monkeypatch.setenv("FRONTEND_BASE_URL", "https://app.example.test")
    monkeypatch.setenv("EHALL_SERVICE_URL", "https://ehall.gzus.edu.cn/shiro-cas")
    monkeypatch.setenv("ECARD_VERIFY_TLS", "true")
    monkeypatch.setenv("RSA_PRIVATE_KEY_PEM", _TEST_RSA_PRIVATE_KEY_PEM)
    get_settings.cache_clear()
    from app import database
    from app.cache_service import reset_cache_factory

    database.reset_engine()
    reset_cache_factory()
    yield
    if os.environ.get("GZUS_TEST_POSTGRES_URL"):
        database.Base.metadata.drop_all(database.get_sync_engine())
    database.reset_engine()
    reset_cache_factory()
    get_settings.cache_clear()
