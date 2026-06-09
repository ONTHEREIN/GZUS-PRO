from fastapi.testclient import TestClient

from app.ecard_client import EcardClient, EcardConfigurationError, EcardRoomRef, calc_sign
from app.jobs import ecard_reminder_message
from app.main import app
from app.routes import ecard


class FakeSchoolClient:
    def get_info(self):
        return {"studentId": "20240001", "name": "测试用户"}

    def logout(self):
        pass


def test_calc_sign_sorts_and_excludes_token_sign():
    params = {"b": "2", "a": "1", "token": "test-token", "sign": "old"}
    assert calc_sign(params, secret="greatge") == "12C3DE5975DA50A59D217B32A1DCEE1D"


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


def test_summary_not_bound_returns_status(monkeypatch):
    with TestClient(app) as client:
        session = app.state.sessions.create(FakeSchoolClient(), "测试用户")
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
