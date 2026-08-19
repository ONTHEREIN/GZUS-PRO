"""生产环境配置校验测试。

conftest 默认把 DEBUG 设为 true，本文件显式模拟生产配置（DEBUG=false）
验证 fail-fast 校验，特别是 RSA_PRIVATE_KEY 冷启动密钥漂移防护。
"""
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.config import get_settings


def _pem_key() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


@pytest.fixture
def _production_env(monkeypatch):
    """模拟生产环境：DEBUG=false + 其余必须项齐全。"""
    monkeypatch.setenv("DEBUG", "false")
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@neon.example/db")
    monkeypatch.setenv("CREDENTIAL_ENCRYPTION_KEY", "prod-credential-key")
    monkeypatch.setenv("PUBLIC_API_BASE_URL", "https://api.example.test")
    monkeypatch.setenv("FRONTEND_BASE_URL", "https://app.example.test")
    monkeypatch.delenv("RSA_PRIVATE_KEY", raising=False)
    monkeypatch.delenv("RSA_PRIVATE_KEY_PEM", raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_production_requires_rsa_private_key(_production_env):
    """生产缺少 RSA_PRIVATE_KEY 必须拒绝启动，避免冷启动生成随机密钥。"""
    with pytest.raises(RuntimeError, match="RSA_PRIVATE_KEY"):
        get_settings()


def test_production_accepts_rsa_private_key(_production_env, monkeypatch):
    """配置了合法 RSA 私钥（RSA_PRIVATE_KEY 环境变量路径）后校验通过。"""
    monkeypatch.setenv("RSA_PRIVATE_KEY", _pem_key())
    get_settings.cache_clear()
    settings = get_settings()  # 不应抛 RuntimeError
    assert settings.debug is False


def test_rsa_key_manager_uses_configured_key(_production_env, monkeypatch):
    """rsa_key_manager 应加载配置的固定私钥（keyId 稳定，不随冷启动漂移）。"""
    from app.rsa_keys import RsaKeyManager

    pem = _pem_key()
    monkeypatch.setenv("RSA_PRIVATE_KEY", pem)
    manager = RsaKeyManager()

    # 用同一把私钥的两个实例应得到相同 keyId；公钥 PEM 可导出。
    assert manager.get_key_id() == RsaKeyManager().get_key_id()
    assert "PUBLIC KEY" in manager.get_public_key_pem()
