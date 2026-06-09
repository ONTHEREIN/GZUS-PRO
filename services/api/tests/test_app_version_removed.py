from fastapi.testclient import TestClient

from app.main import create_app


def test_app_version_route_removed():
    client = TestClient(create_app())

    response = client.get("/app/version")

    assert response.status_code == 404
