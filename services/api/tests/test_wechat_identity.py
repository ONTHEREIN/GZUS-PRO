import httpx
import pytest

from app.config import get_settings
from app import wechat_identity


class FakeResponse:
    def __init__(self, payload: object, error: Exception | None = None) -> None:
        self.payload = payload
        self.error = error

    def raise_for_status(self) -> None:
        if self.error is not None:
            raise self.error

    def json(self) -> object:
        return self.payload


class FakeClient:
    def __init__(self, response: FakeResponse, requests: list[dict[str, object]]) -> None:
        self.response = response
        self.requests = requests

    def __enter__(self) -> "FakeClient":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        return None

    def get(self, url: str, params: dict[str, str]) -> FakeResponse:
        self.requests.append({"url": url, "params": params})
        return self.response


def test_exchange_code_success_never_logs_sensitive_values(monkeypatch, caplog) -> None:
    app_secret = "test-app-secret"
    one_time_code = "test-one-time-code"
    openid = "test-openid"
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-test-app")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", app_secret)
    get_settings.cache_clear()
    requests: list[dict[str, object]] = []
    fake_client = FakeClient(FakeResponse({"errcode": 0, "openid": openid}), requests)
    monkeypatch.setattr(wechat_identity.httpx, "Client", lambda timeout: fake_client)

    result = wechat_identity.exchange_code(one_time_code)

    assert result.app_id == "wx-test-app"
    assert result.openid == openid
    assert requests[0]["url"] == "https://api.weixin.qq.com/sns/jscode2session"
    assert requests[0]["params"] == {
        "appid": "wx-test-app",
        "secret": app_secret,
        "js_code": one_time_code,
        "grant_type": "authorization_code",
    }
    assert app_secret not in caplog.text
    assert one_time_code not in caplog.text
    assert openid not in caplog.text


def test_exchange_code_retries_transport_failure_then_succeeds(monkeypatch) -> None:
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-test-app")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "test-app-secret")
    get_settings.cache_clear()
    responses = [
        FakeResponse({}, httpx.ConnectError("temporary")),
        FakeResponse({}, httpx.ReadTimeout("temporary")),
        FakeResponse({"openid": "test-openid"}),
    ]
    requests: list[dict[str, object]] = []

    def make_client(timeout: int) -> FakeClient:
        return FakeClient(responses.pop(0), requests)

    monkeypatch.setattr(wechat_identity.httpx, "Client", make_client)
    monkeypatch.setattr(wechat_identity.time, "sleep", lambda seconds: None)

    result = wechat_identity.exchange_code("test-one-time-code")

    assert result.openid == "test-openid"
    assert len(requests) == 3


def test_exchange_code_rejects_wechat_error_and_missing_configuration(monkeypatch) -> None:
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-test-app")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "test-app-secret")
    get_settings.cache_clear()
    error_client = FakeClient(FakeResponse({"errcode": 40029, "errmsg": "invalid code"}), [])
    monkeypatch.setattr(wechat_identity.httpx, "Client", lambda timeout: error_client)

    with pytest.raises(wechat_identity.WechatIdentityError, match="凭证无效"):
        wechat_identity.exchange_code("test-one-time-code")

    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "")
    get_settings.cache_clear()
    with pytest.raises(wechat_identity.WechatNotConfiguredError, match="尚未配置"):
        wechat_identity.exchange_code("test-one-time-code")
