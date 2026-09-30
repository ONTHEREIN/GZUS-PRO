import time

from fastapi.testclient import TestClient

from app.main import create_app
from app.rate_limit import limiter
from app.routes import weather


def test_weather_endpoint_limits_anonymous_requests() -> None:
    limiter.reset()
    weather._cache.clear()
    weather._cache["default"] = ({"city": "广州"}, time.time())
    try:
        with TestClient(create_app()) as client:
            responses = [client.get("/weather") for _ in range(31)]
        assert [response.status_code for response in responses] == [200] * 30 + [429]
    finally:
        weather._cache.clear()
        limiter.reset()
