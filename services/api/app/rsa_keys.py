import base64
import hashlib

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


class RsaKeyManager:
    def __init__(self) -> None:
        # Try config first (supports .env files), then fall back to env var
        pem = ""
        try:
            from app.config import get_settings
            pem = get_settings().rsa_private_key_pem.strip()
        except Exception:
            pass
        if not pem:
            import os
            pem = os.environ.get("RSA_PRIVATE_KEY", "").strip()

        if pem:
            self._private_key = _load_private_key(pem)
        else:
            # 仅开发/测试环境允许临时生成：生产环境 get_settings() 会在
            # 缺少 RSA_PRIVATE_KEY 时直接拒绝启动（config.py 校验），
            # 避免 serverless 冷启动每实例一把新密钥导致 keyId 漂移。
            self._private_key = rsa.generate_private_key(
                public_exponent=65537,
                key_size=2048,
            )

        pub_der = self._private_key.public_key().public_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        self._key_id = hashlib.sha256(pub_der).hexdigest()[:12]

    def get_public_key_pem(self) -> str:
        return self._private_key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        ).decode()

    def get_key_id(self) -> str:
        return self._key_id

    def decrypt(self, base64_ciphertext: str) -> str:
        try:
            ciphertext = base64.b64decode(base64_ciphertext)
            plaintext = self._private_key.decrypt(
                ciphertext,
                padding.PKCS1v15(),
            )
            return plaintext.decode()
        except Exception as exc:
            raise ValueError("RSA decryption failed") from exc


def _load_private_key(value: str) -> rsa.RSAPrivateKey:
    """加载 PEM，或环境文件中单行存储的 Base64 PEM。"""
    pem_bytes = value.encode()
    if not value.lstrip().startswith("-----BEGIN"):
        try:
            pem_bytes = base64.b64decode(value, validate=True)
        except ValueError as exc:
            raise ValueError("RSA 私钥必须是 PEM 或 Base64 编码的 PEM") from exc
    loaded_key = serialization.load_pem_private_key(pem_bytes, password=None)
    if not isinstance(loaded_key, rsa.RSAPrivateKey):
        raise ValueError("RSA 私钥不是 RSA 格式")
    return loaded_key


rsa_key_manager = RsaKeyManager()
