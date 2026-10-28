"""span 序号、父子关系与时间轴。

时间轴是「逻辑时钟」：每个 span 的耗时由调用方给出（LLM 调用取录制时的真实耗时，
工具调用取本地实测），t_start_ms 依次累加。这样 replay 出来的 trace 与录制时
在性能维度上一致，不受回放机器快慢影响。
"""

from __future__ import annotations

from typing import Any

from app.agent.spans import (
    GenerateSpan,
    GuardrailSpan,
    ObservationSpan,
    PlanSpan,
    RetrieveSpan,
    Span,
    ToolCallSpan,
)

_KINDS = {
    "plan": PlanSpan,
    "tool_call": ToolCallSpan,
    "observation": ObservationSpan,
    "retrieve": RetrieveSpan,
    "generate": GenerateSpan,
    "guardrail": GuardrailSpan,
}


class Tracer:
    def __init__(self) -> None:
        self.spans: list[Span] = []
        self._clock_ms = 0.0

    def add(
        self, kind: str, *, latency_ms: float = 0.0, parent: str | None = None, **fields: Any,
    ) -> Span:
        step = len(self.spans) + 1
        span = _KINDS[kind](
            span_id=f"s{step}",
            step=step,
            parent=parent,
            t_start_ms=round(self._clock_ms, 1),
            latency_ms=int(round(latency_ms)),
            **fields,
        )
        self._clock_ms += latency_ms
        self.spans.append(span)
        return span

    def advance(self, latency_ms: float) -> None:
        """记一段不单独成 span 的耗时（如 LLM 决定调用哪些工具的那次请求）。"""
        self._clock_ms += latency_ms

    @property
    def elapsed_ms(self) -> float:
        return round(self._clock_ms, 1)
