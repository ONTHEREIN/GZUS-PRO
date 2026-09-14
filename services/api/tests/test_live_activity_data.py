from app.apns_service import build_live_activity_payload
from app.live_activity_data import grade_live_fields, utility_live_metrics


def test_grade_live_fields_prefers_official_status():
    assert grade_live_fields({"score": "95", "status": "补考通过"}) == {
        "score": "95",
        "gradeStatus": "补考通过",
        "gradePassed": True,
        "gradeStatusSource": "official",
    }


def test_grade_live_fields_uses_sixty_point_fallback_and_unknown_state():
    assert grade_live_fields({"score": "60"})["gradeStatus"] == "合格"
    assert grade_live_fields({"score": "59"})["gradeStatus"] == "不及格"
    assert grade_live_fields({"score": "优秀"})["gradeStatus"] == "成绩已发布"


def test_utility_live_metrics_keeps_three_values_and_marks_alert():
    metrics, urgent = utility_live_metrics(
        {
            "coldWaterBalance": 2,
            "coldWaterText": "2 吨",
            "hotWaterBalance": 15,
            "hotWaterText": "15 元",
            "powerBalance": 8,
            "powerText": "8 度",
        },
        30,
        5,
        10,
    )
    assert [item["label"] for item in metrics] == ["冷水", "热水", "电费"]
    assert [item["isAlert"] for item in metrics] == [True, False, True]
    assert urgent is not None
    assert urgent["label"] == "冷水"


def test_live_activity_payload_transmits_structured_fields():
    payload = build_live_activity_payload(
        "start",
        "考试提醒",
        "高等数学",
        {
            "id": "exam:1",
            "type": "exam_reminder",
            "targetTab": "exams",
            "location": "A101",
            "seat": "12",
            "priority": 1,
            "utilityMetrics": [],
        },
    )
    import json

    decoded = json.loads(payload)
    state = decoded["aps"]["content-state"]
    assert state["location"] == "A101"
    assert state["seat"] == "12"
    assert decoded["aps"]["attributes"]["priority"] == 1
