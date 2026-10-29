"""智能体对话端点：agent core 的 HTTP 薄封装。

- 默认关闭（AGENT_ENABLED=false 时 404），只在本地演示时打开；
- 只对演示账号会话开放：数据源是演示账号的虚构数据，给真实学生用会答非所问；
- 每轮对话的 trace 追加写入 data/traces/<YYYYMMDD>.jsonl，字段对齐 AgentLens Trace，
  可直接用 AgentLens 回看。
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from app.academic_period import now_shanghai
from app.agent.cli import load_env_file
from app.agent.core import run_agent
from app.agent.datasource import AgentContext, FixtureSource
from app.agent.llm import LLMClient, OpenAIClient
from app.agent.spans import SCHEMA_VERSION
from app.config import get_settings
from app.routes.deps import require_session
from app.sessions import AppSession

router = APIRouter(prefix="/agent", tags=["agent"])

TRACE_DIR = Path(__file__).resolve().parents[2] / "data" / "traces"
MAX_TURNS = 20


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=2000)


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1, max_length=MAX_TURNS * 2)
    conversation_id: str | None = Field(default=None, alias="conversationId", max_length=64)


def make_llm() -> LLMClient:
    """测试中替换为回放客户端。"""
    load_env_file()
    return OpenAIClient()


@router.post("/chat")
async def chat(payload: ChatRequest, session: AppSession = Depends(require_session)) -> dict[str, Any]:
    if not get_settings().agent_enabled:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")
    if not session.is_demo:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="智能体当前仅对演示账号开放")
    if payload.messages[-1].role != "user":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="最后一条消息必须来自用户")

    messages = [m.model_dump() for m in payload.messages]
    now = now_shanghai()
    ctx = AgentContext(now.date())
    try:
        llm = make_llm()
    except KeyError:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="智能体未配置模型")
    out = await run_in_threadpool(run_agent, messages, ctx=ctx, source=FixtureSource(ctx), llm=llm)

    conversation_id = payload.conversation_id or uuid.uuid4().hex[:12]
    turn = sum(1 for m in messages if m["role"] == "user")
    _append_trace(out.model_dump(mode="json"), conversation_id, turn, now.strftime("%Y%m%d"))
    return {
        "conversationId": conversation_id,
        "turn": turn,
        "status": out.status,
        "answer": out.answer,
        "latencyMs": out.latency_ms,
        "spans": [s.model_dump(mode="json") for s in out.spans],
    }


def _append_trace(out: dict[str, Any], conversation_id: str, turn: int, day: str) -> None:
    trace = {
        "schema_version": SCHEMA_VERSION,
        "run_id": f"chat-{day}",
        "case_id": f"{conversation_id}#{turn}",
        "adapter": "onegzus",
        "conversation_id": conversation_id,
        "turn": turn,
        "model": out["meta"].get("model", "unknown"),
        **out,
    }
    TRACE_DIR.mkdir(parents=True, exist_ok=True)
    with (TRACE_DIR / f"{day}.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(trace, ensure_ascii=False) + "\n")
