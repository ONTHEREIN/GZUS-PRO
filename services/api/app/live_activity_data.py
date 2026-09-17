"""Live Activity 展示所需的结构化数据归一化。"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Final


_OFFICIAL_STATUS_KEYS: Final[tuple[str, ...]] = (
    "gradeStatus",
    "grade_status",
    "status",
    "resultStatus",
    "result_status",
    "passStatus",
    "pass_status",
    "isPass",
    "is_pass",
    "passed",
    "sfjg",
)
_PASS_VALUES: Final[frozenset[str]] = frozenset(
    {"合格", "及格", "通过", "已通过", "pass", "passed", "qualified", "true", "1"}
)
_FAIL_VALUES: Final[frozenset[str]] = frozenset(
    {"不及格", "不通过", "未通过", "挂科", "fail", "failed", "unqualified", "false", "0"}
)
_LIVE_ACTIVITY_PRIORITIES: Final[dict[str, int]] = {
    "course_reminder": 2,
    "exam_reminder": 3,
    "business_reminder": 3,
    "grade_update": 4,
    "attendance_update": 4,
    "business_update": 4,
    "new_notice": 4,
    "ecard_reminder": 5,
}


def live_activity_priority(notification_type: str, ongoing: bool) -> int:
    """返回统一的展示相关性等级；该值不参与服务端投递决策。"""
    if ongoing and notification_type in {"course_reminder", "exam_reminder"}:
        return 1
    return _LIVE_ACTIVITY_PRIORITIES.get(notification_type, 5)


def _text(value: object) -> str:
    return str(value).strip() if value not in (None, "") else ""


def _parse_passed(value: object) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    text = _text(value).lower()
    if text in _PASS_VALUES:
        return True
    if text in _FAIL_VALUES:
        return False
    if any(marker in text for marker in ("不及格", "不通过", "未通过", "挂科", "failed", "fail")):
        return False
    if any(marker in text for marker in ("合格", "及格", "通过", "passed", "pass", "qualified")):
        return True
    return None


def _score_passed(score: str) -> bool | None:
    normalized = score.removesuffix("分").strip()
    try:
        return float(normalized) >= 60
    except ValueError:
        return None


def grade_live_fields(grade: Mapping[str, object]) -> dict[str, object]:
    """返回成绩 Live Activity 字段；优先教务结论，缺失时才使用 60 分规则。"""
    score = _text(grade.get("score") or grade.get("exam_score") or grade.get("cj"))
    official_value = next(
        (grade[key] for key in _OFFICIAL_STATUS_KEYS if key in grade and grade[key] not in (None, "")),
        None,
    )
    official_text = _text(official_value)
    official_passed = _parse_passed(official_value)
    if official_text:
        status = official_text
        passed = official_passed
        source = "official"
    else:
        passed = _score_passed(score)
        status = "合格" if passed is True else "不及格" if passed is False else "成绩已发布"
        source = "score" if passed is not None else "unknown"
    return {
        "score": score or None,
        "gradeStatus": status,
        "gradePassed": passed,
        "gradeStatusSource": source,
    }


def utility_live_metrics(
    summary: Mapping[str, object],
    low_power_threshold: float,
    low_cold_water_threshold: float,
    low_hot_water_threshold: float,
) -> tuple[list[dict[str, object]], dict[str, object] | None]:
    """生成水电三项结构化余额，并返回紧凑态使用的最紧急项。"""
    definitions = (
        ("冷水", "coldWaterBalance", "coldWaterText", low_cold_water_threshold),
        ("热水", "hotWaterBalance", "hotWaterText", low_hot_water_threshold),
        ("电费", "powerBalance", "powerText", low_power_threshold),
    )
    metrics: list[dict[str, object]] = []
    for label, balance_key, text_key, threshold in definitions:
        raw_balance = summary.get(balance_key)
        value = _text(summary.get(text_key)) or _text(raw_balance)
        if not value:
            continue
        numeric_balance: float | None
        try:
            numeric_balance = float(raw_balance) if raw_balance not in (None, "") else None
        except (TypeError, ValueError):
            numeric_balance = None
        metrics.append(
            {
                "label": label,
                "value": value,
                "isAlert": numeric_balance is not None and numeric_balance < threshold,
                "balance": numeric_balance,
            }
        )
    if not metrics:
        return [], None
    urgent = min(
        metrics,
        key=lambda item: (
            not bool(item["isAlert"]),
            float(item["balance"]) if item["balance"] is not None else float("inf"),
        ),
    )
    return metrics, urgent
