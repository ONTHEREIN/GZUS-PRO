from fastapi.testclient import TestClient

from app.main import create_app


def test_localhost_random_port_preflight_is_allowed():
    client = TestClient(create_app())

    response = client.options(
        "/auth/login",
        headers={
            "Origin": "http://localhost:19231",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:19231"
