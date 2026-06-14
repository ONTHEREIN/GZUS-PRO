from fastapi.testclient import TestClient

from app.config import get_settings
from app.ecard_client import EcardClient, EcardConfigurationError, EcardRoomRef, calc_sign
from app.jobs import ecard_reminder_message
from app.main import app
from app.routes import ecard
from app.sessions import AppSession


class FakeSchoolClient:
    def get_info(self):
        return {"studentId": "20240001", "name": "测试用户"}

    def logout(self):
        pass


def test_calc_sign_sorts_and_excludes_token_sign():
    params = {"b": "2", "a": "1", "token": "test-token", "sign": "old"}
    assert calc_sign(params, secret="sample-signing-key") == "AEF5932236C4957DF1288BEFA61BD466"


def test_login_request_omits_unionid(monkeypatch):
    """登录请求不得携带 unionid，否则学校返回 code=203 未登录。

    回归测试：见 ecard_client.py 中 post_api 的注释。
    """
    monkeypatch.setenv("ECARD_OPENID", "openid-abc")
    monkeypatch.setenv("ECARD_UNIONID", "unionid-xyz")
    get_settings.cache_clear()

    client = EcardClient()
    client._worker_proxy_origin = ""  # 强制走直连路径（非代理）
    client._unionid = "unionid-xyz"
    captured = {}

    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return {"code": 200, "token": "tok-1", "unionid": "unionid-xyz"}

    class FakeHttpClient:
        def post(self, url, data=None, headers=None):
            captured["payload"] = dict(data or {})
            return FakeResponse()

        def get(self, url, params=None, timeout=None):
            return FakeResponse()

    monkeypatch.setattr(client, "_get_http_client", lambda: FakeHttpClient())

    token = client.login()
    assert token == "tok-1"
    assert "unionid" not in captured["payload"], (
        "登录请求不应携带 unionid（会导致学校服务端 code=203 未登录）"
    )


def test_authenticated_request_includes_unionid(monkeypatch):
    """已认证（带 token）的业务请求应携带 unionid。"""
    monkeypatch.setenv("ECARD_OPENID", "openid-abc")
    monkeypatch.setenv("ECARD_UNIONID", "unionid-xyz")
    get_settings.cache_clear()

    client = EcardClient()
    client._worker_proxy_origin = ""  # 强制走直连路径（非代理）
    client._token = "tok-1"
    client._unionid = "unionid-xyz"
    captured = []

    class FakeResponse:
        def __init__(self, data):
            self._data = data

        def raise_for_status(self):
            return None

        def json(self):
            return self._data

    class FakeHttpClient:
        def post(self, url, data=None, headers=None):
            captured.append(dict(data or {}))
            return FakeResponse({"ret": True, "obj": {}})

        def get(self, url, params=None, timeout=None):
            return FakeResponse({"ret": True})

    monkeypatch.setattr(client, "_get_http_client", lambda: FakeHttpClient())

    client.post_api("/powerfee/getBalance", {"implType": "CGCOMMON1111"}, token="tok-1")
    assert captured[0].get("unionid") == "unionid-xyz"
    assert captured[0].get("token") == "tok-1"


def test_rooms_do_not_expose_balances(monkeypatch):
    client = object.__new__(EcardClient)
    client._token = "token"

    def fake_post_api(path, params=None, *, token=None):
        return {
            "ret": True,
            "obj": [
                {
                    "implType": params["implType"],
                    "schoolAreaNo": "1",
                    "buildingNo": "A2",
                    "roomNum": "932",
                    "schoolArea": "校本部",
                    "building": "A2",
                    "room": "A2#932",
                    "powerBalance": 1,
                    "waterBalance": 2,
                }
            ],
        }

    monkeypatch.setattr(client, "post_api", fake_post_api)
    rooms = client.rooms()
    assert rooms[0] == {
        "id": "CGCOMMON1111|1|A2|932",
        "schoolArea": "校本部",
        "building": "A2",
        "room": "A2-932",
        "displayName": "校本部 A2 A2-932",
    }
    assert "powerBalance" not in rooms[0]
    assert "waterBalance" not in rooms[0]


def test_power_consumption_uses_daily_details():
    client = object.__new__(EcardClient)
    client._token = "token"
    calls = []

    def fake_post_api(path, params=None, *, token=None):
        calls.append((path, params, token))
        return {
            "ret": True,
            "obj": {
                "dailyUsedUnit": "度",
                "dailyDetailsInfos": [
                    {
                        "dateTime": "2026-06-02",
                        "dailyUsed": "23.29",
                        "leftUsed": "159.13",
                        "leftFree": "",
                    }
                ],
            },
        }

    client.post_api = fake_post_api
    data = client.consumption(
        EcardRoomRef("CGCOMMON1111", "1", "A2", "932"),
        "2026-06",
    )
    assert calls == [
        (
            "/powerfee/getDailyDetails",
            {
                "roomNum": "932",
                "lastDate": "2026-06",
                "type": "",
                "implType": "CGCOMMON1111",
                "schoolAreaNo": "1",
                "pageNum": "1",
                "pageSize": "31",
            },
            "token",
        )
    ]
    assert data == {
        "status": "ok",
        "items": [
            {
                "title": "剩余 159.13 度",
                "amount": "23.29 度",
                "time": "2026-06-02",
            }
        ],
    }


def test_proxy_mode_does_not_require_ecard_openid(monkeypatch):
    monkeypatch.setenv("ECARD_OPENID", "")
    monkeypatch.setenv("ECARD_WORKER_PROXY_ORIGIN", "https://edge.example")
    get_settings.cache_clear()

    client = EcardClient()

    assert client._openid == ""
    assert client._worker_proxy_origin == "https://edge.example"


def test_proxy_maps_rooms_balance_and_consumption(monkeypatch):
    monkeypatch.setenv("ECARD_WORKER_PROXY_TOKEN", "proxy-token")
    get_settings.cache_clear()
    calls = []

    class FakeResponse:
        def __init__(self, data):
            self._data = data

        def raise_for_status(self):
            return None

        def json(self):
            return self._data

    class FakeHttpClient:
        def get(self, url, params=None, timeout=None):
            calls.append((url, params, timeout))
            if url.endswith("/rooms"):
                return FakeResponse([{"id": "room-1"}])
            if url.endswith("/balance"):
                return FakeResponse({"powerBalance": 12, "coldWaterBalance": 3})
            if url.endswith("/consumption"):
                return FakeResponse({"status": "ok", "items": [{"title": "剩余 1 度"}]})
            return FakeResponse({})

    client = EcardClient(worker_proxy_origin="https://edge.example")
    monkeypatch.setattr(client, "_get_http_client", lambda: FakeHttpClient())

    rooms = client._post_via_proxy(
        "https://ecarduser.gzus.edu.cn/powerfee/getRoomInfo",
        {"implType": "CGCOMMON1111"},
        {},
    )
    balance = client._post_via_proxy(
        "https://ecarduser.gzus.edu.cn/powerfee/getBalance",
        {
            "implType": "CGCOMMON1111",
            "schoolAreaNo": "1",
            "buildingNo": "A2",
            "roomNum": "932",
            "studentId": "20240001",
        },
        {},
    )
    consumption = client._post_via_proxy(
        "https://ecarduser.gzus.edu.cn/powerfee/getDailyDetails",
        {
            "implType": "CGCOMMON1111",
            "schoolAreaNo": "1",
            "buildingNo": "A2",
            "roomNum": "932",
            "lastDate": "2026-06",
        },
        {},
    )

    assert rooms == {"ret": True, "code": 200, "obj": [{"id": "room-1"}]}
    assert balance == {
        "ret": True,
        "code": 200,
        "obj": {"powerBalance": 12, "coldWaterBalance": 3},
    }
    assert consumption == {"status": "ok", "items": [{"title": "剩余 1 度"}]}
    assert calls[0][0] == "https://edge.example/ecard-proxy/rooms"
    assert calls[0][1] == {"eo_token": "proxy-token"}
    assert calls[1][0] == "https://edge.example/ecard-proxy/balance"
    assert calls[1][1] == {
        "eo_token": "proxy-token",
        "roomId": "CGCOMMON1111|1|A2|932",
        "studentId": "20240001",
    }
    assert calls[2][0] == "https://edge.example/ecard-proxy/consumption"
    assert calls[2][1] == {
        "eo_token": "proxy-token",
        "roomId": "CGCOMMON1111|1|A2|932",
        "month": "2026-06",
    }


def test_summary_not_bound_returns_status(monkeypatch):
    session = AppSession(id="test-session", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    with TestClient(app) as client:
        response = client.get("/ecard/summary", headers={"X-Session-Id": session.id})
    assert response.status_code == 200
    assert response.json()["status"] == "not_bound"


def test_missing_ecard_openid_returns_503(monkeypatch):
    def fail_client():
        raise EcardConfigurationError("未配置 ECARD_OPENID")

    monkeypatch.setattr(ecard, "_client", fail_client)
    with TestClient(app) as client:
        session = app.state.sessions.create(FakeSchoolClient(), "测试用户")
        response = client.get("/ecard/rooms", headers={"X-Session-Id": session.id})
    assert response.status_code == 503


def test_ecard_reminder_message_levels():
    assert ecard_reminder_message({"powerBalance": 9, "powerText": "9 度"}, 30, 5, 10, ["power"])[0][1] == "电量极低"
    assert ecard_reminder_message({"powerBalance": 20, "powerText": "20 度"}, 30, 5, 10, ["power"])[0][1] == "电量偏低"
    assert ecard_reminder_message({"powerBalance": 50, "powerText": "50 度"}, 30, 5, 10, ["power"])[0][1] == "今日水电费"
