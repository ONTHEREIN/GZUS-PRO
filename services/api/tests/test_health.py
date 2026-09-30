from concurrent.futures import Future

from fastapi.testclient import TestClient

from app.main import create_app


def test_liveness_is_available_without_database_work() -> None:
    client = TestClient(create_app())

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_checks_database_and_returns_trace_id() -> None:
    with TestClient(create_app()) as client:
        response = client.get("/health/ready", headers={"X-GZUS-Trace-Id": "health-test"})

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert response.headers["X-GZUS-Trace-Id"] == "health-test"


def test_readiness_fails_when_background_poller_stops() -> None:
    app = create_app()
    stopped = Future()
    stopped.set_exception(RuntimeError("一卡通轮询退出"))
    app.state.poller_tasks["ecard"] = stopped

    response = TestClient(app).get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
