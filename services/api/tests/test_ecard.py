from fastapi.testclient import TestClient

from app.config import get_settings
from app.database import EcardBinding, get_sync_session_factory
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

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
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


def test_rooms_fill_missing_impl_type_from_current_source_and_dedupe(monkeypatch):
    client = object.__new__(EcardClient)
    client._token = "token"

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
        return {
            "ret": True,
            "obj": [
                {
                    "schoolAreaNo": "1",
                    "buildingNo": "A2",
                    "roomNum": "932",
                    "schoolArea": "校本部",
                    "building": "A2",
                    "room": "A2#932",
                }
            ],
        }

    monkeypatch.setattr(client, "post_api", fake_post_api)

    rooms = client.rooms()

    assert rooms == [
        {
            "id": "CGCOMMON1111|1|A2|932",
            "schoolArea": "校本部",
            "building": "A2",
            "room": "A2-932",
            "displayName": "校本部 A2 A2-932",
        }
    ]


def test_rooms_fetch_all_impl_types(monkeypatch):
    client = object.__new__(EcardClient)
    client._token = "token"
    calls = []

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
        impl_type = params["implType"]
        calls.append(impl_type)
        return {
            "ret": True,
            "obj": [
                {
                    "implType": impl_type,
                    "schoolAreaNo": "1",
                    "buildingNo": "A2",
                    "roomNum": impl_type[-4:],
                    "schoolArea": "校本部",
                    "building": "A2",
                    "room": f"A2#{impl_type[-4:]}",
                }
            ],
        }

    monkeypatch.setattr(client, "post_api", fake_post_api)

    rooms = client.rooms()

    assert set(calls) == {"CGCOMMON1111", "CGCOMMON2222", "CGCOMMON3333"}
    assert [room["id"] for room in rooms] == [
        "CGCOMMON1111|1|A2|1111",
        "CGCOMMON2222|1|A2|2222",
        "CGCOMMON3333|1|A2|3333",
    ]


def test_rooms_raise_when_all_fetches_fail(monkeypatch):
    client = object.__new__(EcardClient)
    client._token = "token"

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
        raise RuntimeError("proxy failed")

    monkeypatch.setattr(client, "post_api", fake_post_api)

    try:
        client.rooms()
    except Exception as exc:
        assert type(exc).__name__ == "EcardApiError"
        assert str(exc) == "获取宿舍列表失败"
    else:
        raise AssertionError("rooms() should not return an empty list when every fetch fails")


def test_rooms_raise_when_all_fetches_return_errors(monkeypatch):
    client = object.__new__(EcardClient)
    client._token = "token"

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
        return {"ret": False, "code": 500, "msg": "upstream unavailable"}

    monkeypatch.setattr(client, "post_api", fake_post_api)

    try:
        client.rooms()
    except Exception as exc:
        assert type(exc).__name__ == "EcardApiError"
        assert str(exc) == "获取宿舍列表失败"
    else:
        raise AssertionError("rooms() should not return an empty list when every source errors")


def test_power_consumption_uses_daily_details():
    client = object.__new__(EcardClient)
    client._token = "token"
    calls = []

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
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


def test_balance_uses_room_ref_and_hot_water_student_fallback():
    client = object.__new__(EcardClient)
    client._token = "token"
    calls = []

    def fake_post_api(path, params=None, *, token=None, timeout=None, proxy_origin=None):
        calls.append((path, params, token))
        if path == "/powerfee/getBalance":
            return {
                "ret": True,
                "obj": {
                    "powerBalance": "116.41",
                    "formatPowerBalanceStr": "116.41 度",
                    "waterBalance": "9.99",
                    "formatWaterBalanceStr": "9.99 吨",
                },
            }
        if path == "/waterfee/memberInfo":
            return {"ret": True, "obj": {"balance": 15.176}}
        raise AssertionError(path)

    client.post_api = fake_post_api

    summary = client.balance(
        EcardRoomRef("CGCOMMON2222", "82", "5328", "5611"),
        "2540232101",
    )

    assert calls == [
        (
            "/powerfee/getBalance",
            {
                "implType": "CGCOMMON2222",
                "schoolAreaNo": "82",
                "buildingNo": "5328",
                "roomNum": "5611",
                "studentId": "2540232101",
            },
            "token",
        ),
        (
            "/waterfee/memberInfo",
            {"sno": "2540232101", "implType": "MINGHANBLUETOOTH"},
            "token",
        ),
    ]
    assert summary["powerBalance"] == "116.41"
    assert summary["powerText"] == "116.41 度"
    assert summary["coldWaterBalance"] == "9.99"
    assert summary["coldWaterText"] == "9.99 吨"
    assert summary["hotWaterBalance"] == 15.176
    assert summary["hotWaterText"] == "15.176 元"


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


def test_rooms_route_filters_by_display_building_room_and_area(monkeypatch):
    session = AppSession(id="rooms-filter", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)
    monkeypatch.setattr(
        ecard,
        "_get_rooms_cached",
        lambda: [
            {
                "id": "CGCOMMON1111|1|A2|932",
                "schoolArea": "校本部",
                "building": "A2",
                "room": "A2-932",
                "displayName": "校本部 A2 A2-932",
            },
            {
                "id": "CGCOMMON1111|2|B1|101",
                "schoolArea": "江门校区",
                "building": "B1",
                "room": "B1-101",
                "displayName": "江门校区 B1 B1-101",
            },
        ],
    )

    with TestClient(app) as client:
        for query in ("校本部 A2 A2-932", "A2", "932", "校本部"):
            response = client.get(
                f"/ecard/rooms?q={query}",
                headers={"X-Session-Id": session.id},
            )
            assert response.status_code == 200
            assert [item["id"] for item in response.json()] == ["CGCOMMON1111|1|A2|932"]


def test_update_summary_cache_requires_session():
    with TestClient(app) as client:
        response = client.patch("/ecard/summary-cache", json={"powerBalance": 9})
    assert response.status_code == 401


def test_update_summary_cache_requires_binding(monkeypatch):
    session = AppSession(id="cache-no-binding", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    with TestClient(app) as client:
        response = client.patch(
            "/ecard/summary-cache",
            headers={"X-Session-Id": session.id},
            json={"powerBalance": 9},
        )
    assert response.status_code == 404


def test_update_summary_cache_only_updates_balance_snapshot(monkeypatch):
    session = AppSession(id="cache-bound", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            EcardBinding(
                student_id="20240001",
                room_id="CGCOMMON1111|1|A2|932",
                room_display="校本部 A2 A2-932",
                reminder_enabled=False,
                low_power_threshold=15,
                last_summary_json=(
                    '{"roomId": "CGCOMMON2222|9|B1|101", "powerBalance": 3, "powerText": "3 度"}'
                ),
            )
        )
        db.commit()

    with TestClient(app) as client:
        response = client.patch(
            "/ecard/summary-cache",
            headers={"X-Session-Id": session.id},
            json={
                "powerBalance": 9,
                "powerText": "9 度",
                "coldWaterBalance": 2,
                "coldWaterText": "2 吨",
                "updatedAt": "2026-06-16T12:00:00",
            },
        )

    assert response.status_code == 200
    data = response.json()
    assert data["roomId"] == "CGCOMMON1111|1|A2|932"
    assert data["roomDisplay"] == "校本部 A2 A2-932"
    assert data["powerBalance"] == 9
    assert data["powerText"] == "9 度"
    assert data["coldWaterBalance"] == 2
    assert data["reminderEnabled"] is False
    assert data["lowPowerThreshold"] == 15


def test_update_summary_cache_rejects_binding_fields(monkeypatch):
    session = AppSession(id="cache-invalid", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            EcardBinding(
                student_id="20240001",
                room_id="CGCOMMON1111|1|A2|932",
                room_display="校本部 A2 A2-932",
            )
        )
        db.commit()

    with TestClient(app) as client:
        response = client.patch(
            "/ecard/summary-cache",
            headers={"X-Session-Id": session.id},
            json={"roomId": "CGCOMMON2222|9|B1|101", "powerBalance": 9},
        )

    assert response.status_code == 422


def test_refresh_returns_cached_summary_when_upstream_fails(monkeypatch):
    session = AppSession(id="refresh-cache", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    class FailingClient:
        def balance(self, room_ref, student_id):
            raise ecard.EcardApiError("一卡通服务请求失败")

    monkeypatch.setattr(ecard, "_client", lambda: FailingClient())

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            EcardBinding(
                student_id="20240001",
                room_id="CGCOMMON1111|1|A2|932",
                room_display="校本部 A2 A2-932",
                last_summary_json='{"powerBalance": 9, "powerText": "9 度"}',
            )
        )
        db.commit()

    with TestClient(app) as client:
        response = client.post("/ecard/refresh", headers={"X-Session-Id": session.id})

    assert response.status_code == 200
    data = response.json()
    assert data["roomDisplay"] == "校本部 A2 A2-932"
    assert data["powerBalance"] == 9
    assert data["powerText"] == "9 度"


def test_consumption_returns_limited_when_upstream_fails(monkeypatch):
    session = AppSession(id="consumption-limited", client=FakeSchoolClient(), student_name="测试用户")
    monkeypatch.setattr(app.state.sessions, "get", lambda session_id, touch=True: session)
    monkeypatch.setattr(app.state.sessions, "touch", lambda session_id: None)

    class FailingClient:
        def consumption(self, room_ref, month):
            raise ecard.EcardApiError("一卡通服务请求失败")

    monkeypatch.setattr(ecard, "_client", lambda: FailingClient())

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            EcardBinding(
                student_id="20240001",
                room_id="CGCOMMON1111|1|A2|932",
                room_display="校本部 A2 A2-932",
            )
        )
        db.commit()

    with TestClient(app) as client:
        response = client.get("/ecard/consumption", headers={"X-Session-Id": session.id})

    assert response.status_code == 200
    assert response.json() == {"status": "limited", "message": "消费记录暂时不可用", "items": []}


def test_ecard_reminder_message_levels():
    assert (
        ecard_reminder_message({"powerBalance": 9, "powerText": "9 度"}, 30, 5, 10, ["power"])[0][1]
        == "电量极低"
    )
    assert (
        ecard_reminder_message({"powerBalance": 20, "powerText": "20 度"}, 30, 5, 10, ["power"])[0][
            1
        ]
        == "电量偏低"
    )
    assert (
        ecard_reminder_message({"powerBalance": 50, "powerText": "50 度"}, 30, 5, 10, ["power"])[0][
            1
        ]
        == "今日水电费"
    )
