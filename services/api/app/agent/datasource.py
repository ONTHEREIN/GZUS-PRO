"""智能体的数据源 seam。

`AgentDataSource` 是 agent 能看到的全部数据面。三态实现：
- `FixtureSource`：本文件，包 `app.demo_data` 的虚构演示数据，确定性、零网络；
- `SchoolSource`：生产态，包真实学校客户端（未实现，阶段一不接真实系统）；
- `FaultySource`：故障注入，包任意 source（M3）。

返回值统一为 `DataResult`，`error_kind` 是有限枚举：归因要按错误类型区分，
不能靠错误字符串猜。
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any, Callable, Generic, Literal, Protocol, TypeVar

from app.academic_period import SHANGHAI_TZ, academic_period_of, default_first_week_start
from app.demo_data import DemoAcademicClient, DemoEhallClient, demo_ecard_summary
from app.schemas import (
    AttendanceItem,
    AttendanceResponse,
    EcardSummary,
    ExamItem,
    GradeItem,
    NoticeItem,
    ScheduleCourse,
)

ErrorKind = Literal[
    "auth_expired", "upstream_timeout", "empty", "not_implemented", "schema_mismatch",
]

T = TypeVar("T")


@dataclass
class DataResult(Generic[T]):
    ok: bool
    data: T | None = None
    error_kind: ErrorKind | None = None
    latency_ms: float = 0.0


@dataclass(frozen=True)
class Period:
    """学年/学期，与 `app.academic_period` 同一约定：year 为学年起始年，term 为 1/2。"""

    year: int
    term: int

    @property
    def label(self) -> str:
        """成绩条目里的学期写法，如 2025-2026-2。"""
        return f"{self.year}-{self.year + 1}-{self.term}"


@dataclass
class NoticeHit:
    item: NoticeItem
    score: float
    chunk_id: str


@dataclass
class AgentContext:
    """一次执行的外部上下文。today 固定后，同一用例在任何日期回放结果都一致。"""

    today: date
    current: Period = field(init=False)
    week: int = field(init=False)

    def __post_init__(self) -> None:
        year, term = academic_period_of(_as_datetime(self.today))
        self.current = Period(year, term)
        start = default_first_week_start(year, term)
        self.week = max(1, (self.today - start).days // 7 + 1)


class AgentDataSource(Protocol):
    def schedule(self, week: int | None) -> DataResult[list[ScheduleCourse]]: ...
    def grades(self, period: Period) -> DataResult[list[GradeItem]]: ...
    def attendance(self, period: Period) -> DataResult[AttendanceResponse]: ...
    def exams(self, period: Period) -> DataResult[list[ExamItem]]: ...
    def card_balance(self) -> DataResult[EcardSummary]: ...
    def notices(self, keyword: str) -> DataResult[list[NoticeHit]]: ...


class FixtureSource:
    """虚构演示数据源。

    演示客户端本身不区分学期；这里按真实接口的语义补上学期过滤：成绩、考勤按
    条目自带的学年学期归属，课表与考试视为「当前学期」的数据。查其他学期返回
    空列表（ok=True、0 行），与真实接口查无数据时的表现一致。
    """

    def __init__(self, ctx: AgentContext, extra_notices: list[dict[str, Any]] | None = None) -> None:
        self.ctx = ctx
        self._academic = DemoAcademicClient()
        self._ehall = DemoEhallClient()
        # 测试注入点：用例追加的通知（如藏指令的间接注入样本），与演示通知一起被检索
        self._extra_notices = list(extra_notices or [])

    def schedule(self, week: int | None) -> DataResult[list[ScheduleCourse]]:
        def load() -> list[ScheduleCourse]:
            target = week or self.ctx.week
            rows = self._academic.get_schedule(None, None)
            return [ScheduleCourse(**r) for r in rows if _in_weeks(target, str(r.get("weeks")))]

        return _timed(load)

    def grades(self, period: Period) -> DataResult[list[GradeItem]]:
        def load() -> list[GradeItem]:
            rows = self._academic.get_grades(str(period.year), str(period.term))
            return [GradeItem(**r) for r in rows if r.get("term") == period.label]

        return _timed(load)

    def attendance(self, period: Period) -> DataResult[AttendanceResponse]:
        def load() -> AttendanceResponse:
            year_label = f"{period.year}-{period.year + 1}"
            rows = self._academic.get_attendance(str(period.year), str(period.term))
            items = [
                AttendanceItem(**r) for r in rows
                if r.get("academicYear") == year_label and str(r.get("term")) == str(period.term)
            ]
            return AttendanceResponse(status="ok", items=items)

        return _timed(load)

    def exams(self, period: Period) -> DataResult[list[ExamItem]]:
        def load() -> list[ExamItem]:
            if period != self.ctx.current:
                return []
            return [ExamItem(**r) for r in self._academic.get_exams(None, None)]

        return _timed(load)

    def card_balance(self) -> DataResult[EcardSummary]:
        return _timed(lambda: EcardSummary(**demo_ecard_summary()))

    def notices(self, keyword: str) -> DataResult[list[NoticeHit]]:
        def load() -> list[NoticeHit]:
            rows = (
                self._academic.get_notices() + self._ehall.get_notice_items() + self._extra_notices
            )
            hits = []
            for idx, row in enumerate(rows):
                item = NoticeItem(**row)
                score = _overlap(keyword, f"{item.title} {item.summary or ''}")
                if score > 0:
                    hits.append(NoticeHit(item=item, score=score, chunk_id=item.url or f"n{idx}"))
            return sorted(hits, key=lambda h: h.score, reverse=True)

        return _timed(load)


def _timed(load: Callable[[], Any]) -> DataResult[Any]:
    start = time.perf_counter()
    data = load()
    return DataResult(ok=True, data=data, latency_ms=(time.perf_counter() - start) * 1000)


def _in_weeks(week: int, spec: str) -> bool:
    """解析 "1-16" / "1-8,10,12-14" 形式的周次。"""
    for part in spec.replace("，", ",").split(","):
        bounds = part.strip().split("-")
        try:
            lo, hi = int(bounds[0]), int(bounds[-1])
        except ValueError:
            continue
        if lo <= week <= hi:
            return True
    return False


def _bigrams(text: str) -> set[str]:
    text = "".join(text.split())
    return {text[i : i + 2] for i in range(len(text) - 1)} or ({text} if text else set())


def _overlap(query: str, doc: str) -> float:
    """关键词与文档的字符二元组重合率，作为检索得分（0~1）。"""
    q = _bigrams(query)
    if not q:
        return 0.0
    return round(len(q & _bigrams(doc)) / len(q), 3)


def _as_datetime(d: date) -> datetime:
    return datetime(d.year, d.month, d.day, 12, tzinfo=SHANGHAI_TZ)
