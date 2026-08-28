from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import create_app


def test_localhost_random_port_preflight_is_allowed():
    client = TestClient(create_app())

    response = client.options(
        "/auth/auto-login",
        headers={
            "Origin": "http://localhost:19231",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:19231"


def test_preflight_allows_admin_delete_method():
    """管理后台的 DELETE 端点（/admin/users/{id} 等）需通过 CORS 预检。"""
    client = TestClient(create_app())

    response = client.options(
        "/admin/users/123",
        headers={
            "Origin": "http://localhost:19231",
            "Access-Control-Request-Method": "DELETE",
            "Access-Control-Request-Headers": "content-type, x-session-id",
        },
    )

    assert response.status_code == 200
    allow_methods = response.headers.get("access-control-allow-methods", "")
    assert "DELETE" in allow_methods


def test_security_headers_are_set():
    client = TestClient(create_app())

    response = client.get("/health")

    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["referrer-policy"] == "strict-origin-when-cross-origin"


def test_ly_sso_start_sanitizes_external_return_url():
    app = create_app()
    client = TestClient(app)

    response = client.get(
        "/auth/ly/start",
        params={"return_url": "https://evil.example/callback"},
        follow_redirects=False,
    )

    assert response.status_code in {302, 307}
    pending = list(app.state.ly_sso_states.values())
    assert len(pending) == 1
    assert pending[0].return_url == get_settings().frontend_base_url


def test_ly_sso_callback_rejects_unknown_state():
    client = TestClient(create_app())

    response = client.get(
        "/auth/ly/callback",
        params={"ticket": "ST-1", "state": "missing"},
        follow_redirects=False,
    )

    assert response.status_code == 400
