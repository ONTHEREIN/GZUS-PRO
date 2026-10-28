"""agent core：护栏 → 规划 → tool-calling 循环 → 生成。

每一步都落成一个 span，span 的含义与 AgentLens 的断言一一对应：
guardrail(L6) / plan(L1) / tool_call(L2、L3) / observation、retrieve(L5) / generate(L4)。
"""

from __future__ import annotations

import json
from typing import Any

from app.agent import policy
from app.agent.datasource import AgentContext, AgentDataSource
from app.agent.llm import LLMClient, ReplayExhausted
from app.agent.spans import AgentOutput, RetrieveSpan, TokenUsage
from app.agent.tools import TOOLS, openai_tools, run_tool
from app.agent.tracer import Tracer

MAX_ROUNDS = 8
_WEEKDAYS = "一二三四五六日"

PLAN_TOOL = {
    "type": "function",
    "function": {
        "name": "make_plan",
        "description": "在调用任何工具之前，写下你对用户意图的理解和打算调用的工具顺序",
        "parameters": {
            "type": "object",
            "properties": {
                "intent": {"type": "string", "description": "一句话概括用户想要什么"},
                "steps": {
                    "type": "array",
                    "items": {"type": "string", "enum": list(TOOLS)},
                    "description": "按顺序列出要调用的工具名；不需要工具时为空数组",
                },
            },
            "required": ["intent", "steps"],
        },
    },
}


def system_prompt(ctx: AgentContext) -> str:
    cur = ctx.current
    return (
        "你是「软帮手」校园助手，帮学生查询本人的课表、成绩、考勤、考试安排、宿舍水电余额和学校通知。\n"
        f"今天是 {ctx.today.isoformat()}（星期{_WEEKDAYS[ctx.today.weekday()]}），"
        f"当前是 {cur.year}-{cur.year + 1} 学年第 {cur.term} 学期第 {ctx.week} 周。\n"
        "工作方式：\n"
        "1. 先调用 make_plan，写下你对用户意图的理解和打算调用的工具顺序；\n"
        "2. 再调用工具获取数据。回答必须以工具返回的数据为依据，不要编造工具没有返回的内容；\n"
        '3. 工具参数中，学年 year 填学年起始年份（2025-2026 学年填 "2025"），'
        '学期 term 填 "1"（秋季学期）或 "2"（春季学期）；\n'
        "4. 用简洁的中文回答。"
    )


def run_agent(
    messages: list[dict[str, str]],
    *,
    ctx: AgentContext,
    source: AgentDataSource,
    llm: LLMClient,
) -> AgentOutput:
    """执行一轮对话。messages 为历史 + 本轮用户消息（最后一条必须是 user）。"""
    tracer = Tracer()
    tokens = TokenUsage()
    meta: dict[str, Any] = {"model": llm.model, "today": ctx.today.isoformat()}

    def finish(status: str, answer: str = "", **extra: Any) -> AgentOutput:
        return AgentOutput(
            status=status, answer=answer, spans=tracer.spans, tokens=tokens,
            latency_ms=tracer.elapsed_ms, meta={**meta, **extra},
        )

    user_text = messages[-1]["content"]
    decision = policy.check(user_text)
    if decision.action == "refuse":
        tracer.add(
            "guardrail", triggered=True, rule=decision.rule, action="refuse", reason=decision.reason,
        )
        return finish("ok", policy.REFUSAL)

    convo: list[dict[str, Any]] = [{"role": "system", "content": system_prompt(ctx)}, *messages]

    def ask(tools: list[dict[str, Any]], tool_choice: Any):
        reply = llm.complete(convo, tools, tool_choice)
        tokens.prompt += reply.prompt_tokens
        tokens.completion += reply.completion_tokens
        convo.append(reply.as_message())
        return reply

    # make_plan 与业务工具一起提供，由 prompt 要求先规划，不强制 tool_choice：
    # 部分模型（如 DeepSeek 思考模式）不支持指定函数。模型跳过规划时就没有
    # plan span，这是真实的被测行为，由 AgentLens 归到 L1。
    tools = [PLAN_TOOL, *openai_tools()]
    plan_id = None
    try:
        for _ in range(MAX_ROUNDS):
            reply = ask(tools, "auto")
            if not reply.tool_calls:
                answer = reply.content or ""
                tracer.add(
                    "generate", latency_ms=reply.latency_ms, answer_ref="answer",
                    citations=_citations(tracer, answer),
                )
                return finish("ok", answer)
            # 本轮的 LLM 决策耗时：有规划就记在 plan span 上，否则记在 tool_call 之前
            decided = False
            for call in reply.tool_calls:
                if call.name == "make_plan":
                    plan = _loads(call.arguments)
                    span = tracer.add(
                        "plan", latency_ms=0 if decided else reply.latency_ms,
                        intent=str(plan.get("intent", "")),
                        steps=[str(s) for s in plan.get("steps") or []],
                        notes=reply.reasoning,
                    )
                    plan_id = plan_id or span.span_id
                    content = "计划已记录，请开始执行。"
                else:
                    if not decided:
                        tracer.advance(reply.latency_ms)
                    content = run_tool(
                        call.name, call.arguments, source=source, ctx=ctx, tracer=tracer,
                        parent=plan_id,
                    )
                decided = True
                convo.append({"role": "tool", "tool_call_id": call.id, "content": content})
        return finish("error", error="max_rounds", detail=f"{MAX_ROUNDS} 轮内未给出最终回答")
    except ReplayExhausted as exc:
        return finish("error", error="replay_exhausted", detail=str(exc))


def _loads(raw: str) -> dict[str, Any]:
    try:
        value = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _citations(tracer: Tracer, answer: str) -> list[str]:
    """检索到、且标题出现在回答里的通知，记为引用。"""
    cited = []
    for span in tracer.spans:
        if isinstance(span, RetrieveSpan):
            cited.extend(cid for cid in span.chunk_ids if cid not in cited)
    return [cid for cid in cited if _title_in(tracer, cid, answer)]


def _title_in(tracer: Tracer, chunk_id: str, answer: str) -> bool:
    for span in tracer.spans:
        if span.span == "observation" and isinstance(span.raw, list):
            for row in span.raw:
                if isinstance(row, dict) and row.get("url") == chunk_id:
                    return bool(row.get("title")) and row["title"] in answer
    return False
