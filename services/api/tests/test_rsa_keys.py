import base64

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.rsa_keys import _load_private_key


def test_load_private_key_accepts_base64_encoded_pem():
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )

    loaded_key = _load_private_key(base64.b64encode(pem).decode())

    assert loaded_key.private_numbers() == private_key.private_numbers()
