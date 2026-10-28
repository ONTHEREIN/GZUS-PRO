"""LLM 客户端：真实调用、录制、回放三种实现共用一个接口。

录制文件只存 LLM 的回复序列（含 tool_calls、token 与耗时），不存工具返回：
回放时工具照常走数据源重新执行。所以回放出来的 trace 是「真实决策 + 真实执行」，
不是伪造的 span。
"""

from __future__ import annotations

import os
import time
from dataclasses import asdict, dataclass, field
from typing import Any, Protocol

REPLAY_FORMAT = 1


@dataclass
class ToolCallReq:
    id: str
    name: str
    arguments: str


@dataclass
class LLMReply:
    content: str | None
    tool_calls: list[ToolCallReq] = field(default_factory=list)
    # 思考模式模型（如 DeepSeek）的推理文本：同一轮工具调用中必须原样回传
    reasoning: str | None = None
    prompt_tokens: int = 0
    completion_tokens: int = 0
    latency_ms: float = 0.0

    def as_message(self) -> dict[str, Any]:
        msg: dict[str, Any] = {"role": "assistant", "content": self.content}
        if self.reasoning is not None:
            msg["reasoning_content"] = self.reasoning
        if self.tool_calls:
            msg["tool_calls"] = [
                {"id": c.id, "type": "function", "function": {"name": c.name, "arguments": c.arguments}}
                for c in self.tool_calls
            ]
        return msg


class LLMClient(Protocol):
    model: str

    def complete(
        self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], tool_choice: Any,
    ) -> LLMReply: ...


class ReplayExhausted(RuntimeError):
    """回放的回复已用完：agent 代码的调用序列与录制时不一致，需要重新录制。"""


class OpenAIClient:
    """OpenAI 兼容接口（含国产模型）。配置走环境变量，key 不落盘。"""

    def __init__(self) -> None:
        from openai import OpenAI

        self.model = os.environ["AGENT_LLM_MODEL"]
        self._client = OpenAI(
            api_key=os.environ["AGENT_LLM_API_KEY"],
            base_url=os.environ.get("AGENT_LLM_BASE_URL") or None,
            timeout=float(os.environ.get("AGENT_LLM_TIMEOUT", "60")),
        )

    def complete(self, messages, tools, tool_choice) -> LLMReply:
        start = time.perf_counter()
        resp = self._client.chat.completions.create(
            model=self.model, messages=messages, tools=tools, tool_choice=tool_choice,
            temperature=0,
        )
        latency = (time.perf_counter() - start) * 1000
        msg = resp.choices[0].message
        usage = resp.usage
        return LLMReply(
            content=msg.content,
            tool_calls=[
                ToolCallReq(id=c.id, name=c.function.name, arguments=c.function.arguments or "{}")
                for c in (msg.tool_calls or [])
            ],
            reasoning=getattr(msg, "reasoning_content", None),
            prompt_tokens=usage.prompt_tokens if usage else 0,
            completion_tokens=usage.completion_tokens if usage else 0,
            latency_ms=round(latency, 1),
        )


class RecordingClient:
    """包在真实客户端外面，把每次回复按顺序记下来。"""

    def __init__(self, inner: LLMClient) -> None:
        self.inner = inner
        self.model = inner.model
        self.replies: list[LLMReply] = []

    def complete(self, messages, tools, tool_choice) -> LLMReply:
        reply = self.inner.complete(messages, tools, tool_choice)
        self.replies.append(reply)
        return reply

    def recording(self, input_sha: str) -> dict[str, Any]:
        return {
            "format": REPLAY_FORMAT,
            "model": self.model,
            "input_sha": input_sha,
            "replies": [asdict(r) for r in self.replies],
        }


class ReplayClient:
    def __init__(self, recording: dict[str, Any]) -> None:
        if recording.get("format") != REPLAY_FORMAT:
            raise ValueError(f"不支持的录制格式：{recording.get('format')}")
        self.model = recording["model"]
        self._replies = [
            LLMReply(
                content=r["content"],
                tool_calls=[ToolCallReq(**c) for c in r["tool_calls"]],
                reasoning=r.get("reasoning"),
                prompt_tokens=r["prompt_tokens"],
                completion_tokens=r["completion_tokens"],
                latency_ms=r["latency_ms"],
            )
            for r in recording["replies"]
        ]
        self._cursor = 0

    def complete(self, messages, tools, tool_choice) -> LLMReply:
        if self._cursor >= len(self._replies):
            raise ReplayExhausted(f"录制只有 {len(self._replies)} 次回复，agent 请求了第 {self._cursor + 1} 次")
        reply = self._replies[self._cursor]
        self._cursor += 1
        return reply
