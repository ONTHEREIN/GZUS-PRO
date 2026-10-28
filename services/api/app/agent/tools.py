"""智能体的读工具集与执行器。

工具名与参数对齐真实接口（`routes/academic.py` 等）：学年 year 为起始年（"2025"
表示 2025-2026 学年），term 为 "1"/"2"；缺省时与真实接口一样补成当前学期。
参数先过 pydantic 校验，结果写进 tool_call span 的 schema_ok / schema_errors，
这是 AgentLens 判 L3（参数填充）的依据。
"""

from __future__ import annotations

import json
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from app.agent.datasource import AgentContext, AgentDataSource, DataResult, Period
from app.agent.tracer import Tracer

# 观测内联到 trace 的最大行数；超出部分只记 row_count
_RAW_ROWS = 20


class _Args(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ScheduleArgs(_Args):
    week: int | None = Field(default=None, ge=1, le=30, description="教学周，缺省为本周")


class PeriodArgs(_Args):
    year: str | None = Field(
        default=None, pattern=r"^\d{4}$", description="学年起始年，如 2025 表示 2025-2026 学年；缺省为当前学年",
    )
    term: Literal["1", "2"] | None = Field(
        default=None, description="学期：1 为秋季学期，2 为春季学期；缺省为当前学期",
    )

    @field_validator("year", "term", mode="before")
    @classmethod
    def _number_as_text(cls, v: Any) -> Any:
        return str(v) if isinstance(v, int) else v

    def period(self, ctx: AgentContext) -> Period:
        return Period(
            int(self.year) if self.year else ctx.current.year,
            int(self.term) if self.term else ctx.current.term,
        )


class NoArgs(_Args):
    pass


class SearchArgs(_Args):
    keyword: str = Field(min_length=1, description="检索关键词")


TOOLS: dict[str, tuple[type[_Args], str]] = {
    "get_schedule": (ScheduleArgs, "查询本人某一教学周的课表"),
    "get_grades": (PeriodArgs, "查询本人某学年某学期的课程成绩"),
    "get_attendance": (PeriodArgs, "查询本人某学年某学期的考勤统计"),
    "get_exams": (PeriodArgs, "查询本人某学年某学期的考试安排"),
    "get_card_balance": (NoArgs, "查询本人宿舍电费、水费余额"),
    "search_notices": (SearchArgs, "按关键词检索学校通知公告"),
}


def openai_tools() -> list[dict[str, Any]]:
    return [
        {
            "type": "function",
            "function": {
                "name": name,
                "description": desc,
                "parameters": _clean_schema(model.model_json_schema()),
            },
        }
        for name, (model, desc) in TOOLS.items()
    ]


def run_tool(
    name: str,
    raw_args: str,
    *,
    source: AgentDataSource,
    ctx: AgentContext,
    tracer: Tracer,
    parent: str | None,
) -> str:
    """执行一次工具调用并记录 span，返回回填给 LLM 的工具结果文本。"""
    args, errors = _parse_args(name, raw_args)
    call = tracer.add(
        "tool_call", parent=parent, name=name, args=args,
        schema_ok=not errors, schema_errors=errors,
    )
    if errors:
        tracer.add("observation", parent=call.span_id, ok=False, error="invalid_args")
        return _dump({"error": "参数不合法", "details": errors})

    model, _ = TOOLS[name]
    parsed = model.model_validate(args)
    if name == "search_notices":
        result = source.notices(parsed.keyword)
        hits = result.data or []
        tracer.add(
            "retrieve", parent=call.span_id, latency_ms=result.latency_ms, query=parsed.keyword,
            chunk_ids=[h.chunk_id for h in hits], scores=[h.score for h in hits],
        )
        result = DataResult(ok=result.ok, data=[h.item for h in hits], error_kind=result.error_kind)
    elif name == "get_schedule":
        result = source.schedule(parsed.week)
    elif name == "get_card_balance":
        result = source.card_balance()
    else:
        period = parsed.period(ctx)
        result = {
            "get_grades": source.grades,
            "get_attendance": source.attendance,
            "get_exams": source.exams,
        }[name](period)

    payload = _jsonable(result.data)
    rows = _rows(payload)
    tracer.add(
        "observation", parent=call.span_id, latency_ms=result.latency_ms, ok=result.ok,
        row_count=len(rows) if rows is not None else None,
        raw=payload if rows is None or len(rows) <= _RAW_ROWS else rows[:_RAW_ROWS],
        error=result.error_kind,
    )
    if not result.ok:
        return _dump({"error": result.error_kind})
    return _dump(payload)


def _parse_args(name: str, raw: str) -> tuple[dict[str, Any], list[str]]:
    try:
        args = json.loads(raw or "{}")
    except json.JSONDecodeError as exc:
        return {"_raw": raw}, [f"参数不是合法 JSON：{exc.msg}"]
    if not isinstance(args, dict):
        return {"_raw": raw}, ["参数必须是 JSON 对象"]
    if name not in TOOLS:
        return args, [f"未知工具：{name}"]
    try:
        TOOLS[name][0].model_validate(args)
    except ValidationError as exc:
        return args, [
            f"{'.'.join(str(p) for p in e['loc']) or '(root)'}: {e['msg']}" for e in exc.errors()
        ]
    return args, []


def _jsonable(data: Any) -> Any:
    if isinstance(data, BaseModel):
        return data.model_dump(mode="json", by_alias=True, exclude_none=True)
    if isinstance(data, list):
        return [_jsonable(d) for d in data]
    return data


def _rows(payload: Any) -> list[Any] | None:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("items"), list):
        return payload["items"]
    return None


def _dump(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False)


def _clean_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """去掉 pydantic 生成的 title，减少 prompt 噪声。"""
    schema = {k: v for k, v in schema.items() if k != "title"}
    props = schema.get("properties", {})
    schema["properties"] = {
        k: {kk: vv for kk, vv in v.items() if kk != "title"} for k, v in props.items()
    }
    return schema
