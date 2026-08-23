from fastapi.testclient import TestClient

from app.main import create_app


def test_liveness_is_available_without_database_work() -> None:
    client = TestClient(create_app())

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_checks_database_and_returns_trace_id() -> None:
    client = TestClient(create_app())

    response = client.get("/health/ready", headers={"X-GZUS-Trace-Id": "health-test"})

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert response.headers["X-GZUS-Trace-Id"] == "health-test"
