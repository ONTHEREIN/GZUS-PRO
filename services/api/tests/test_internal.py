import pytest
from fastapi.testclient import TestClient

from app.config import get_settings
from app.database import MaintenanceJobStatus, get_sync_session_factory
from app.main import create_app


def _client(monkeypatch: pytest.MonkeyPatch, internal_key: str) -> TestClient:
    monkeypatch.setenv("INTERNAL_API_KEY", internal_key)
    get_settings.cache_clear()
    return TestClient(create_app())


@pytest.mark.parametrize(
    ("configured_key", "request_key", "expected_status"),
    [("", "internal-test-key", 503), ("internal-test-key", "wrong-key", 403)],
)
def test_cron_routes_require_matching_key(
    monkeypatch: pytest.MonkeyPatch,
    configured_key: str,
    request_key: str,
    expected_status: int,
) -> None:
    response = _client(monkeypatch, configured_key).get(
        "/internal/cron/wechat-sync",
        headers={"X-Internal-Key": request_key},
    )

    assert response.status_code == expected_status


def test_worker_bridge_endpoints_are_removed(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _client(monkeypatch, "internal-test-key")

    assert client.post("/internal/decrypt-password").status_code == 404
    assert client.post("/internal/create-session").status_code == 404


def test_cron_success_persists_monitoring_status(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _client(monkeypatch, "internal-test-key")

    response = client.get(
        "/internal/cron/wechat-sync",
        headers={"X-Internal-Key": "internal-test-key"},
    )

    assert response.status_code == 200
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(MaintenanceJobStatus, "wechat-sync")
        assert row is not None
        assert row.last_succeeded_at is not None
        assert row.last_error is None
        assert row.last_duration_ms is not None
