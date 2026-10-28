"""AgentLens trace span 的镜像模型（对齐 AgentLens schema v0.2）。

两个仓库之间只靠 JSON 契约连接，不共享包。这里与 AgentLens `agentlens/schema.py`
的 span 定义逐字段对应，并同样拒绝未知字段：字段不对就在软帮手侧写出前失败，
而不是写出去再让 AgentLens 报错。改字段必须两边同步。
"""

from __future__ import annotations

from typing import Annotated, Any, Literal, Union

from pydantic import BaseModel, ConfigDict, Field

SCHEMA_VERSION = "0.2"


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class BaseSpan(_Strict):
    span_id: str
    step: int
    parent: str | None = None
    t_start_ms: float = 0.0
    latency_ms: int = 0


class PlanSpan(BaseSpan):
    span: Literal["plan"] = "plan"
    intent: str
    steps: list[str] = Field(default_factory=list)
    notes: str | None = None


class ToolCallSpan(BaseSpan):
    span: Literal["tool_call"] = "tool_call"
    name: str
    args: dict[str, Any] = Field(default_factory=dict)
    schema_ok: bool = True
    schema_errors: list[str] = Field(default_factory=list)


class ObservationSpan(BaseSpan):
    span: Literal["observation"] = "observation"
    ok: bool = True
    row_count: int | None = None
    raw: Any = None
    raw_ref: str | None = None
    error: str | None = None


class RetrieveSpan(BaseSpan):
    span: Literal["retrieve"] = "retrieve"
    query: str
    chunk_ids: list[str] = Field(default_factory=list)
    scores: list[float] = Field(default_factory=list)


class GenerateSpan(BaseSpan):
    span: Literal["generate"] = "generate"
    answer_ref: str | None = None
    citations: list[str] = Field(default_factory=list)


class GuardrailSpan(BaseSpan):
    span: Literal["guardrail"] = "guardrail"
    triggered: bool = False
    rule: str | None = None
    action: Literal["allow", "refuse", "rewrite"] = "allow"
    reason: str | None = None


Span = Annotated[
    Union[PlanSpan, ToolCallSpan, ObservationSpan, RetrieveSpan, GenerateSpan, GuardrailSpan],
    Field(discriminator="span"),
]


class TokenUsage(_Strict):
    prompt: int = 0
    completion: int = 0


class AgentOutput(_Strict):
    """一次执行的产物，与 AgentLens `adapters/base.py: AgentOutput` 同构。"""

    status: Literal["ok", "error", "timeout", "blocked"] = "ok"
    answer: str = ""
    spans: list[Span] = Field(default_factory=list)
    tokens: TokenUsage = Field(default_factory=TokenUsage)
    latency_ms: float = 0.0
    meta: dict[str, Any] = Field(default_factory=dict)
