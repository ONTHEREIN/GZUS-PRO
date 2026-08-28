"""学年/学期判定与开学日期推导的单一事实来源。

规则（与前端 `schedule_utils.dart` 保持一致）：
- 月份启发式：8-12 月、1 月 → 第 1 学期（秋）；2-7 月 → 第 2 学期（春）。
  学年从 8 月跨年（8 月起的学年号 = 当前自然年），暑假按即将开学处理。
- 若已保存各学期开学日期（first_weeks，键 "{year}-{term}"），可用
  `period_from_first_weeks` 按日期区间反推当前学期，比启发式更贴合真实校历。

时间判定一律使用 Asia/Shanghai 时区：naive now 在
跨月边界会偏差最多 8 小时，导致取错学年/学期的课表、成绩、考试数据。
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

SHANGHAI_TZ = ZoneInfo("Asia/Shanghai")

# 学期最大周数，与前端 weekFromDate 的 clamp 上限一致。
MAX_TERM_WEEKS = 30

_TERM_WEEK_DELTA = timedelta(weeks=MAX_TERM_WEEKS)


def now_shanghai() -> datetime:
    """当前上海时间（与服务器时区无关）。"""
    return datetime.now(SHANGHAI_TZ)


def academic_period_of(dt: datetime) -> tuple[int, int]:
    """按月份启发式推导 (学年, 学期)；8-12 月/1 月为第 1 学期，2-7 月为第 2 学期。"""
    academic_year = dt.year if dt.month >= 8 else dt.year - 1
    academic_term = 1 if dt.month >= 8 or dt.month == 1 else 2
    return academic_year, academic_term


def default_first_week_start(year: int, term: int) -> date:
    """推导学期第一周周一：第 1 学期（秋）9 月 1 日起，第 2 学期（春）次年 3 月 1 日起。"""
    seed = date(year, 9, 1) if term == 1 else date(year + 1, 3, 1)
    return seed - timedelta(days=seed.weekday())


def _parse_first_week_entry(key: str, value: str) -> tuple[int, int, date] | None:
    """解析 "{year}-{term}" 键与 yyyy-MM-dd 值；格式非法返回 None。"""
    parts = key.split("-")
    if len(parts) != 2:
        return None
    try:
        year, term = int(parts[0]), int(parts[1])
        start = date.fromisoformat(value)
    except ValueError:
        return None
    if term not in (1, 2):
        return None
    return year, term, start


def period_from_first_weeks(
    first_weeks: dict[str, str],
    dt: datetime | None = None,
) -> tuple[int, int] | None:
    """用已保存的开学日期反推当前学期。

    学期区间为 [开学周一, 开学周一 + 30 周)；相邻学期区间可能重叠，多个命中时
    取开学日期最新者。新学年已开始时，不允许上学年的遗留记录回退学期；无命中或
    数据缺失返回 None（调用方回退月份启发式）。
    """
    target = dt or now_shanghai()
    today = target.date()
    current_academic_year, _ = academic_period_of(target)
    best: tuple[date, int, int] | None = None
    for key, value in first_weeks.items():
        parsed = _parse_first_week_entry(str(key), str(value))
        if parsed is None:
            continue
        year, term, start = parsed
        if year < current_academic_year:
            continue
        if start <= today < start + _TERM_WEEK_DELTA and (best is None or start > best[0]):
            best = (start, year, term)
    if best is None:
        return None
    return best[1], best[2]


def default_academic_period(year: str | int | None, term: str | int | None) -> tuple[int, int]:
    """学年/学期兜底：显式传参优先，缺失项按上海时间的月份启发式补齐。"""
    if year not in (None, "") and term not in (None, ""):
        return int(year), int(term)
    academic_year, academic_term = academic_period_of(now_shanghai())
    return int(year or academic_year), int(term or academic_term)
