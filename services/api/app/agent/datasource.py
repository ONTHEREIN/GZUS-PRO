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
from typing import Any, Callable, Generic, Literal, Protocol, TypeVar, get_args

from pydantic import BaseModel

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


FAULT_SOURCES = ("schedule", "grades", "attendance", "exams", "card_balance", "notices")


@dataclass(frozen=True)
class Fault:
    """一处注入：让某个数据源返回错误（error_kind 之一）、静默篡改返回的字段（patch），
    或照常返回但变慢（slow，只叠加 latency_ms，不真的 sleep）。

    patch 用对外 JSON 字段名（如 powerBalance、score）；where 为空时作用于全部条目。
    """

    source: str
    kind: str
    set: dict[str, Any] = field(default_factory=dict)
    where: dict[str, Any] = field(default_factory=dict)
    latency_ms: float = 0.0

    @classmethod
    def parse(cls, raw: dict[str, Any]) -> "Fault":
        fault = cls(**raw)
        if fault.source not in FAULT_SOURCES:
            raise ValueError(f"未知数据源：{fault.source}")
        if fault.kind not in (*get_args(ErrorKind), "patch", "slow"):
            raise ValueError(f"未知故障类型：{fault.kind}")
        if fault.kind == "patch" and not fault.set:
            raise ValueError("patch 故障需要 set")
        if fault.kind == "slow" and fault.latency_ms <= 0:
            raise ValueError("slow 故障需要 latency_ms > 0")
        return fault


class FaultySource:
    """故障注入：包在任意数据源外面，按 Fault 列表改写指定数据源的返回。

    给 AgentLens 测「数据面出问题时 agent 怎么说」：接口报错时是否如实告知、
    数据被篡改时答案是否仍忠实于观测（此时根因在 L5 数据源，而非 L4 解读）。
    """

    def __init__(self, inner: AgentDataSource, faults: list[Fault]) -> None:
        self._inner = inner
        self._faults = {f.source: f for f in faults}

    def __getattr__(self, name: str) -> Any:
        method = getattr(self._inner, name)
        fault = self._faults.get(name)
        if fault is None:
            return method

        def wrapped(*args: Any) -> DataResult[Any]:
            result = method(*args)
            latency = result.latency_ms + fault.latency_ms
            if fault.kind == "slow":
                return DataResult(ok=result.ok, data=result.data, error_kind=result.error_kind, latency_ms=latency)
            if fault.kind != "patch":
                return DataResult(ok=False, error_kind=fault.kind, latency_ms=latency)  # type: ignore[arg-type]
            return DataResult(ok=result.ok, data=_patch(result.data, fault), latency_ms=latency)

        return wrapped


def _patch(data: Any, fault: Fault) -> Any:
    if isinstance(data, list):
        return [_patch(d, fault) for d in data]
    if isinstance(data, NoticeHit):
        return NoticeHit(item=_patch(data.item, fault), score=data.score, chunk_id=data.chunk_id)
    if isinstance(data, AttendanceResponse):
        return data.model_copy(update={"items": [_patch(i, fault) for i in data.items]})
    if isinstance(data, BaseModel):
        row = data.model_dump(by_alias=True)
        if all(row.get(k) == v for k, v in fault.where.items()):
            return type(data).model_validate({**row, **fault.set})
    return data


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
