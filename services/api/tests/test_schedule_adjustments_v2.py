"""真实路由与数据库验证调课预览、原子提交和撤销。"""

from fastapi.testclient import TestClient
from app.main import app
from test_schedule_adjustments import _authed_session

BASE = "/settings/schedule/adjustments/v2"


def setup(monkeypatch):
    session = _authed_session(monkeypatch)
    session.student_account = "20240001"
    session.client.get_schedule = lambda year, term: [
        {
            "name": "数学",
            "weekday": 1,
            "startSection": 3,
            "endSection": 4,
            "weeks": "1-3",
            "teacher": "甲",
            "classroom": "101",
            "raw": {"kch": "M"},
        },
        {
            "name": "重叠课程",
            "weekday": 1,
            "startSection": 4,
            "endSection": 4,
            "weeks": "1",
            "teacher": "乙",
            "classroom": "102",
            "raw": {"kch": "O"},
        },
        {
            "name": "英语",
            "weekday": 1,
            "startSection": 7,
            "endSection": 9,
            "weeks": "1",
            "teacher": "丙",
            "classroom": "103",
            "raw": {"kch": "E"},
        },
    ]
    return {"X-Session-Id": session.id}


def request(key, action):
    return {
        "schemaVersion": 2,
        "year": 2026,
        "term": 1,
        "firstWeekStart": "2026-09-07",
        "operation": "course",
        "pairs": [
            {
                "sourceDate": "2026-09-07",
                "targetDate": "2026-09-07",
                "sourceStart": 4,
                "sourceEnd": 4,
                "targetStart": 8,
                "sourceKeys": [key],
                "action": action,
            }
        ],
    }


def effective(client, headers):
    response = client.get(
        "/schedule/effective?year=2026&term=1&firstWeekStart=2026-09-07&refresh=false",
        headers=headers,
    )
    assert response.status_code == 200, response.text
    return response.json()


def save(client, headers, payload, client_id):
    result = client.post(f"{BASE}/preview", headers=headers, json=payload)
    assert result.status_code == 200, result.text
    response = client.post(
        BASE,
        headers=headers,
        json={**payload, "clientId": client_id, "fingerprint": result.json()["fingerprint"]},
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_partial_overwrite_and_restore(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as client:
        original = effective(client, headers)
        key = next(
            r["itemKey"] for r in original if r["date"] == "2026-09-07" and r["name"] == "数学"
        )
        payload = request(key, "choose")
        pending = client.post(f"{BASE}/preview", headers=headers, json=payload)
        assert pending.status_code == 200, pending.text
        assert not pending.json()["ready"]
        payload["pairs"][0]["action"] = "replace"
        save(client, headers, payload, "selected")
        monday = [r for r in effective(client, headers) if r["date"] == "2026-09-07"]
        assert {(r["name"], r["startSection"], r["endSection"]) for r in monday} == {
            ("数学", 3, 3),
            ("数学", 8, 8),
            ("重叠课程", 4, 4),
            ("英语", 7, 7),
            ("英语", 9, 9),
        }
        assert (
            client.get(
                "/settings/schedule/adjustments?year=2026&term=1", headers=headers
            ).status_code
            == 409
        )
        body = {
            "year": 2026,
            "term": 1,
            "firstWeekStart": "2026-09-07",
            "expectedRevision": 1,
            "fingerprint": None,
        }
        result = client.post(f"{BASE}/selected/restore-preview", headers=headers, json=body)
        assert result.status_code == 200, result.text
        response = client.post(
            f"{BASE}/selected/restore",
            headers=headers,
            json={**body, "fingerprint": result.json()["fingerprint"]},
        )
        assert response.status_code == 200, response.text
        assert effective(client, headers) == original


def test_swap_all_overlaps_and_idempotency(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as client:
        key = next(
            r["itemKey"]
            for r in effective(client, headers)
            if r["date"] == "2026-09-07" and r["name"] == "数学"
        )
        payload = request(key, "swap")
        row = save(client, headers, payload, "swap")
        assert any(
            r["name"] == "重叠课程" and r["startSection"] == 8 for r in effective(client, headers)
        )
        response = client.post(
            BASE,
            headers=headers,
            json={
                **payload,
                "clientId": "swap",
                "fingerprint": row["metadata"]["preview"]["fingerprint"],
            },
        )
        assert response.status_code == 201
        assert response.json()["id"] == row["id"]
        payload["pairs"][0]["action"] = "replace"
        assert (
            client.post(
                BASE, headers=headers, json={**payload, "clientId": "swap", "fingerprint": "a" * 64}
            ).status_code
            == 409
        )


def test_stale_preview_and_dependency(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as client:
        key = next(
            r["itemKey"]
            for r in effective(client, headers)
            if r["date"] == "2026-09-07" and r["name"] == "数学"
        )
        payload = request(key, "replace")
        stale = client.post(f"{BASE}/preview", headers=headers, json=payload).json()
        save(client, headers, payload, "first")
        second = request(
            next(
                r["itemKey"]
                for r in effective(client, headers)
                if r["name"] == "数学" and r["date"] == "2026-09-14"
            ),
            "move",
        )
        second["pairs"][0].update(sourceDate="2026-09-14", targetDate="2026-09-15", targetStart=4)
        assert (
            client.post(
                BASE,
                headers=headers,
                json={**second, "clientId": "stale", "fingerprint": stale["fingerprint"]},
            ).status_code
            == 409
        )
        moved = next(
            r["itemKey"]
            for r in effective(client, headers)
            if r["date"] == "2026-09-07" and r["name"] == "数学" and r["startSection"] == 8
        )
        later = request(moved, "move")
        later["pairs"][0].update(sourceStart=8, sourceEnd=8, targetStart=11)
        save(client, headers, later, "later")
        body = {
            "year": 2026,
            "term": 1,
            "firstWeekStart": "2026-09-07",
            "expectedRevision": 1,
            "fingerprint": None,
        }
        result = client.post(f"{BASE}/first/restore-preview", headers=headers, json=body).json()
        assert result["blockers"] == ["later"]
        assert (
            client.post(
                f"{BASE}/first/restore",
                headers=headers,
                json={**body, "fingerprint": result["fingerprint"]},
            ).status_code
            == 409
        )


def test_day_empty_pair_atomicity_and_same_day_validation(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as client:
        original = effective(client, headers)
        payload = {
            "schemaVersion": 2,
            "year": 2026,
            "term": 1,
            "firstWeekStart": "2026-09-07",
            "operation": "day",
            "pairs": [
                {
                    "sourceDate": "2026-09-07",
                    "targetDate": "2026-09-08",
                    "sourceStart": 1,
                    "sourceEnd": 16,
                    "targetStart": 1,
                    "sourceKeys": [],
                    "action": "swap",
                },
                {
                    "sourceDate": "2026-09-09",
                    "targetDate": "2026-09-10",
                    "sourceStart": 1,
                    "sourceEnd": 16,
                    "targetStart": 1,
                    "sourceKeys": [],
                    "action": "swap",
                },
            ],
        }
        assert client.post(f"{BASE}/preview", headers=headers, json=payload).status_code == 422
        assert effective(client, headers) == original
        payload["pairs"].pop()
        save(client, headers, payload, "day")
        assert len([r for r in effective(client, headers) if r["date"] == "2026-09-08"]) == 3
        bad = request("any", "swap")
        bad["pairs"][0]["targetStart"] = 4
        assert client.post(f"{BASE}/preview", headers=headers, json=bad).status_code == 422
