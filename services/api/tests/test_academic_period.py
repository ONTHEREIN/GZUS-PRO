"""academic_period 模块单元测试：启发式判定、firstWeeks 反推、兜底函数与开学日期推导。"""

from datetime import date, datetime

from app.academic_period import (
    SHANGHAI_TZ,
    academic_period_of,
    default_academic_period,
    default_first_week_start,
    now_shanghai,
    period_from_first_weeks,
)


def _shanghai(
    year: int, month: int, day: int, hour: int = 12, minute: int = 0
) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=SHANGHAI_TZ)


def test_academic_period_of_boundaries():
    # 9 月 1 日 0 点起进入新学年第 1 学期
    assert academic_period_of(_shanghai(2026, 9, 1, 0)) == (2026, 1)
    # 8 月 31 日仍是上学年第 2 学期
    assert academic_period_of(_shanghai(2026, 8, 31, 23, 59)) == (2025, 2)
    # 1 月 31 日仍是秋季学期（第 1 学期），学年为上一年
    assert academic_period_of(_shanghai(2027, 1, 31)) == (2026, 1)
    # 2 月 1 日起为第 2 学期
    assert academic_period_of(_shanghai(2027, 2, 1, 0)) == (2026, 2)
    # 春季学期中段
    assert academic_period_of(_shanghai(2027, 6, 15)) == (2026, 2)


def test_default_first_week_start_is_monday():
    # 2026-09-01 是周二，其所在周周一为 2026-08-31
    assert default_first_week_start(2026, 1) == date(2026, 8, 31)
    # 2027-03-01 本身是周一
    assert default_first_week_start(2026, 2) == date(2027, 3, 1)


def test_period_from_first_weeks_hit():
    first_weeks = {"2026-1": "2026-08-31", "2026-2": "2027-03-01"}
    # 第 1 学期开学日当天命中
    assert period_from_first_weeks(first_weeks, _shanghai(2026, 8, 31)) == (2026, 1)
    # 寒假期间仍落在第 1 学期区间（新学期开学日前）
    assert period_from_first_weeks(first_weeks, _shanghai(2027, 2, 15)) == (2026, 1)
    # 第 2 学期开学日命中
    assert period_from_first_weeks(first_weeks, _shanghai(2027, 3, 1)) == (2026, 2)


def test_period_from_first_weeks_overlap_prefers_latest_start():
    # 第 1 学期 30 周窗口会覆盖到 3 月，与第 2 学期区间重叠时取开学日期最新者
    first_weeks = {"2026-1": "2026-08-31", "2026-2": "2027-03-01"}
    assert period_from_first_weeks(first_weeks, _shanghai(2027, 3, 15)) == (2026, 2)


def test_period_from_first_weeks_miss_returns_none():
    # 开学日前一天
    assert period_from_first_weeks({"2026-1": "2026-08-31"}, _shanghai(2026, 8, 30)) is None
    # 开学日 30 周之后（区间外）
    assert period_from_first_weeks({"2026-1": "2026-08-31"}, _shanghai(2027, 4, 1)) is None
    # 无数据
    assert period_from_first_weeks({}, _shanghai(2026, 10, 1)) is None


def test_period_from_first_weeks_ignores_invalid_entries():
    first_weeks = {"bad": "2026-08-31", "2026-1": "not-a-date", "2026-3": "2026-09-01"}
    assert period_from_first_weeks(first_weeks, _shanghai(2026, 9, 10)) is None
    # 非法条目与合法条目共存时，合法条目仍可命中
    mixed = {"bad": "x", "2026-1": "2026-08-31"}
    assert period_from_first_weeks(mixed, _shanghai(2026, 9, 10)) == (2026, 1)


def test_default_academic_period_explicit():
    assert default_academic_period("2025", "1") == (2025, 1)
    assert default_academic_period(2025, 2) == (2025, 2)


def test_default_academic_period_derives_from_shanghai_now():
    expected = academic_period_of(now_shanghai())
    assert default_academic_period(None, None) == expected
    assert default_academic_period("", "") == expected


def test_default_academic_period_partial_fill():
    # 只补缺失项：显式学年 + 缺省学期
    year, term = default_academic_period("2025", None)
    assert year == 2025 and term in (1, 2)
    # 显式学期 + 缺省学年
    year2, term2 = default_academic_period(None, "1")
    assert term2 == 1 and year2 in (2024, 2025, 2026)
