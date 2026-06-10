from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization, hashes
import base64
import hashlib


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
            self._private_key = serialization.load_pem_private_key(
                pem.encode(), password=None
            )
        else:
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


rsa_key_manager = RsaKeyManager()
