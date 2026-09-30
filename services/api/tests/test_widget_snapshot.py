from fastapi.testclient import TestClient

from app.main import create_app
from test_academic import FakeClient


class WidgetSchoolClient(FakeClient):
    def get_schedule(self, year, term):
        return [
            {
                "name": "数学",
                "weekday": 1,
                "startSection": 1,
                "endSection": 2,
                "weeks": "1,3-5(单),8(双)",
                "teacher": "老师",
                "classroom": "A101",
                "raw": {"kch": "math"},
            },
            {
                "name": "英语",
                "weekday": 2,
                "startSection": 1,
                "endSection": 2,
                "weeks": "2",
                "teacher": "老师",
                "classroom": "A102",
                "raw": {"kch": "english"},
            },
        ]


def widget_client():
    app = create_app()
    session = app.state.sessions.create(WidgetSchoolClient(), "测试学生")
    return TestClient(app), {"X-Session-Id": session.id}


def widget_context():
    return {
        "year": 2026,
        "term": 1,
        "firstWeekStart": "2026-09-07",
        "overrides": [],
        "pendingAdjustments": [],
    }


def adjustment(client_id, source, target, conflict_mode):
    return {
        "clientId": client_id,
        "year": 2026,
        "term": 1,
        "sourceDate": source,
        "targetDate": target,
        "sourceOccurrenceKeys": [],
        "targetConflictKeys": [],
        "conflictMode": conflict_mode,
    }


def test_widget_post_reads_latest_cloud_adjustments_without_persisting_device_rules():
    client, headers = widget_client()
    context = widget_context()
    cloud = client.post(
        "/settings/schedule/adjustments",
        json=adjustment("cloud", "2026-09-07", "2026-09-14", "coexist"),
        headers=headers,
    )
    assert cloud.status_code == 201
    first = client.post("/widget-snapshot", json=context, headers=headers)
    assert first.status_code == 200
    data = first.json()["modules"]["schedule"]["data"]
    assert all(item["date"] != "2026-09-07" for item in data)
    moved = next(item for item in data if item["date"] == "2026-09-14")
    assert moved["itemKey"] == "course:2026-09-07:math:1:2:老师:A101->2026-09-14"
    assert moved["week"] == 2
    assert (
        client.post(
            "/widget-snapshot",
            json=context,
            headers={**headers, "If-None-Match": first.headers["etag"]},
        ).status_code
        == 304
    )
    assert (
        client.post(
            "/settings/schedule/adjustments/cloud/restore?expectedRevision=1", headers=headers
        ).status_code
        == 200
    )
    latest = client.post(
        "/widget-snapshot",
        json=context,
        headers={**headers, "If-None-Match": first.headers["etag"]},
    )
    assert latest.status_code == 200
    assert any(
        item["date"] == "2026-09-07" for item in latest.json()["modules"]["schedule"]["data"]
    )
    assert (
        len(client.get("/settings/schedule/adjustments?year=2026&term=1", headers=headers).json())
        == 1
    )


def test_widget_post_applies_pending_restore_chained_move_and_conflict_replacement():
    client, headers = widget_client()
    context = widget_context()
    assert (
        client.post(
            "/settings/schedule/adjustments",
            json=adjustment("cloud", "2026-09-07", "2026-09-14", "coexist"),
            headers=headers,
        ).status_code
        == 201
    )
    context["pendingAdjustments"] = [
        {
            **adjustment("cloud", "2026-09-07", "2026-09-14", "coexist"),
            "status": "restored",
            "revision": 2,
        },
        {
            **adjustment("first", "2026-09-07", "2026-09-14", "coexist"),
            "status": "active",
            "revision": 1,
        },
        {
            **adjustment("second", "2026-09-14", "2026-09-15", "replaceConflicts"),
            "status": "active",
            "revision": 1,
        },
    ]
    response = client.post("/widget-snapshot", json=context, headers=headers)
    assert response.status_code == 200
    data = response.json()["modules"]["schedule"]["data"]
    target = [item for item in data if item["date"] == "2026-09-15"]
    assert len(target) == 1 and target[0]["name"] == "数学"
    assert target[0]["itemKey"].endswith("->2026-09-14->2026-09-15")
    assert target[0]["weekday"] == 2
    assert all(item["date"] not in ("2026-09-07", "2026-09-14") for item in data)
    persisted = client.get(
        "/settings/schedule/adjustments?year=2026&term=1", headers=headers
    ).json()
    assert len(persisted) == 1 and persisted[0]["status"] == "active"


def test_widget_post_preserves_empty_schedule_and_week_specific_overrides():
    client, headers = widget_client()
    context = widget_context()
    context["overrides"] = [
        {"id": "hide-math", "matchKey": "kch:math", "weeks": "1", "hidden": True}
    ]
    response = client.post("/widget-snapshot", json=context, headers=headers)
    assert response.status_code == 200
    math = [
        item for item in response.json()["modules"]["schedule"]["data"] if item["name"] == "数学"
    ]
    assert [item["week"] for item in math] == [3, 5, 8]
    context["overrides"] = [
        {"id": "hide-math", "matchKey": "kch:math", "hidden": True},
        {"id": "hide-english", "matchKey": "name:英语", "hidden": True},
    ]
    empty = client.post("/widget-snapshot", json=context, headers=headers)
    assert empty.status_code == 200
    assert empty.json()["modules"]["schedule"]["data"] == []
    assert (
        client.get("/settings/schedule/adjustments?year=2026&term=1", headers=headers).json() == []
    )


def test_widget_post_rejects_unauthed_invalid_scope_and_invalid_dates():
    client, headers = widget_client()
    context = widget_context()
    assert client.post("/widget-snapshot", json=context).status_code == 401
    invalid = {
        **adjustment("pending", "2026-02-30", "2026-09-14", "coexist"),
        "status": "active",
        "revision": 1,
    }
    assert (
        client.post(
            "/widget-snapshot", json={**context, "pendingAdjustments": [invalid]}, headers=headers
        ).status_code
        == 422
    )
    invalid.update(sourceDate="2026-09-07", year=2025)
    assert (
        client.post(
            "/widget-snapshot", json={**context, "pendingAdjustments": [invalid]}, headers=headers
        ).status_code
        == 422
    )


def test_widget_post_ignores_acknowledged_pending_when_cloud_revision_is_newer():
    client, headers = widget_client()
    context = widget_context()
    payload = adjustment("cloud", "2026-09-07", "2026-09-14", "coexist")
    created = client.post("/settings/schedule/adjustments", json=payload, headers=headers)
    assert created.status_code == 201
    context["pendingAdjustments"] = [{**payload, "status": "active", "revision": 1}]
    assert (
        client.post(
            "/settings/schedule/adjustments/cloud/restore?expectedRevision=1", headers=headers
        ).status_code
        == 200
    )
    response = client.post("/widget-snapshot", json=context, headers=headers)
    assert response.status_code == 200
    data = response.json()["modules"]["schedule"]["data"]
    assert any(item["date"] == "2026-09-07" for item in data)
    assert all(not item["itemKey"].endswith("->2026-09-14") for item in data)


def test_widget_post_invalid_school_sections_returns_serializable_502():
    app = create_app()
    school = WidgetSchoolClient()
    school.get_schedule = lambda year, term: [
        {"name": "坏课表", "weekday": 1, "startSection": 2, "endSection": 1}
    ]
    session = app.state.sessions.create(school, "测试学生")
    response = TestClient(app).post(
        "/widget-snapshot", json=widget_context(), headers={"X-Session-Id": session.id}
    )
    assert response.status_code == 502
    assert (
        response.json()["detail"]["errors"][0]["message"] == "Value error, 结束节次不能早于开始节次"
    )
