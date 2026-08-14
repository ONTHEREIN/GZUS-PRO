import base64

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from fastapi.testclient import TestClient

from app.config import get_settings
from app.database import AppSessionModel, get_sync_session_factory
from app.main import create_app
from app.rsa_keys import rsa_key_manager
from app.school_client import SchoolSdkClient
from app.sessions import SessionStore


def _create_internal_client(monkeypatch: pytest.MonkeyPatch, internal_key: str) -> TestClient:
    monkeypatch.setenv("INTERNAL_API_KEY", internal_key)
    get_settings.cache_clear()
    return TestClient(create_app())


def _encrypt_password(password: str) -> str:
    public_key = serialization.load_pem_public_key(
        rsa_key_manager.get_public_key_pem().encode("utf-8")
    )
    ciphertext = public_key.encrypt(password.encode("utf-8"), padding.PKCS1v15())
    return base64.b64encode(ciphertext).decode("ascii")


@pytest.mark.parametrize(
    ("configured_key", "request_key", "expected_status"),
    [
        ("", "internal-test-key", 503),
        ("internal-test-key", "wrong-key", 403),
        ("internal-test-key", "", 403),
    ],
)
def test_internal_routes_require_matching_key(
    monkeypatch: pytest.MonkeyPatch,
    configured_key: str,
    request_key: str,
    expected_status: int,
) -> None:
    client = _create_internal_client(monkeypatch, configured_key)
    headers = {"X-Internal-Key": request_key} if request_key else {}

    response = client.post(
        "/internal/decrypt-password",
        json={"encrypted_password": "invalid"},
        headers=headers,
    )

    assert response.status_code == expected_status


def test_internal_password_decryption_round_trip(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = _create_internal_client(monkeypatch, "internal-test-key")
    encrypted_password = _encrypt_password("测试密码-123")
    headers = {"X-Internal-Key": "internal-test-key"}

    response = client.post(
        "/internal/decrypt-password",
        json={
            "encrypted_password": encrypted_password,
            "key_id": rsa_key_manager.get_key_id(),
        },
        headers=headers,
    )
    assert response.status_code == 200
    assert response.json() == {"password": "测试密码-123"}


def test_internal_password_decryption_rejects_rotated_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = _create_internal_client(monkeypatch, "internal-test-key")
    encrypted_password = _encrypt_password("测试密码-123")
    rotated_key_response = client.post(
        "/internal/decrypt-password",
        json={"encrypted_password": encrypted_password, "key_id": "rotated-key"},
        headers={"X-Internal-Key": "internal-test-key"},
    )
    assert rotated_key_response.status_code == 400
    assert "RSA密钥不匹配" in rotated_key_response.json()["detail"]


def test_internal_create_session_persists_worker_login(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("JWXT_WORKER_PROXY_ORIGIN", "https://edge.example.test")
    client = _create_internal_client(monkeypatch, "internal-test-key")

    response = client.post(
        "/internal/create-session",
        json={
            "account": "20240001",
            "cookies": "route=edge; JSESSIONID=worker-session",
            "student_name": "边缘登录学生",
        },
        headers={"X-Internal-Key": "internal-test-key"},
    )

    assert response.status_code == 200
    session_id = response.json()["sessionId"]
    session = client.app.state.sessions.get(session_id, touch=False)
    assert session is not None
    assert session.student_account == "20240001"
    assert session.student_name == "边缘登录学生"
    assert isinstance(session.client, SchoolSdkClient)
    assert session.client._session_id == session_id
    assert session.client._worker_proxy_origin == "https://edge.example.test"

    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).one()
        assert row.student_account == "20240001"
        assert row.jwxt_cookies is not None
        assert "JSESSIONID=worker-session" in row.jwxt_cookies

    client.app.state.sessions = SessionStore(
        ttl_seconds=7200,
        db_factory=get_sync_session_factory,
    )
    recovered = client.app.state.sessions.get(session_id, touch=False)
    assert recovered is not None
    assert recovered.student_account == "20240001"
    assert isinstance(recovered.client, SchoolSdkClient)
    assert "JSESSIONID=worker-session" in recovered.client.get_jwxt_cookies_string()
