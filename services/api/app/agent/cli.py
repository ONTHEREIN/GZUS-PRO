"""智能体 CLI：AgentLens 在进程外驱动软帮手 agent 的唯一入口。

    echo '{"messages":[{"role":"user","content":"我上学期成绩怎么样"}]}' \\
      | python -m app.agent.cli --mode replay --replay-file rec.json

stdin：{"messages": [...], "today": "2026-09-21"}（today 可省略）
stdout：一行 AgentOutput JSON（与 AgentLens AgentOutput 同构）

- record：调用真实 LLM（AGENT_LLM_API_KEY / AGENT_LLM_MODEL / AGENT_LLM_BASE_URL），
  并把 LLM 回复序列写入 --replay-file
- replay：从 --replay-file 回放 LLM 回复，工具照常执行，全程不联网
- live：调用真实 LLM，不落录制

退出码：0 = 产出了 trace（含 status=error 的 trace）；2 = 输入或录制文件有问题。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import date
from pathlib import Path

from app.agent.core import run_agent
from app.agent.datasource import AgentContext, FixtureSource
from app.agent.llm import OpenAIClient, RecordingClient, ReplayClient

DEFAULT_TODAY = "2026-09-21"
# LLM 配置也可写在这里（KEY=VALUE 每行一条），被 services/api/.gitignore 的 .env* 忽略
ENV_FILE = Path(__file__).resolve().parents[2] / ".env.agent"


def load_env_file(path: Path = ENV_FILE) -> None:
    """把 .env.agent 里的 AGENT_LLM_* 补进环境变量；已存在的环境变量优先。"""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.strip().partition("=")
        if sep and key.startswith("AGENT_LLM_") and key not in os.environ:
            os.environ[key] = value.strip().strip('"').strip("'")


def input_sha(payload: dict) -> str:
    canonical = json.dumps(
        {"messages": payload["messages"], "today": payload.get("today", DEFAULT_TODAY)},
        ensure_ascii=False, sort_keys=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.agent.cli")
    parser.add_argument("--mode", choices=["record", "replay", "live"], default="replay")
    parser.add_argument("--replay-file", type=Path)
    args = parser.parse_args(argv)

    try:
        payload = json.loads(sys.stdin.read())
        messages = payload["messages"]
        if not messages or messages[-1].get("role") != "user":
            raise ValueError("messages 的最后一条必须是 user 消息")
        ctx = AgentContext(date.fromisoformat(payload.get("today", DEFAULT_TODAY)))
    except (ValueError, KeyError, TypeError) as exc:
        print(f"输入不合法：{exc}", file=sys.stderr)
        return 2

    sha = input_sha(payload)
    if args.mode in ("record", "replay") and args.replay_file is None:
        print(f"--mode {args.mode} 需要 --replay-file", file=sys.stderr)
        return 2

    if args.mode == "replay":
        try:
            recording = json.loads(args.replay_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            print(f"没有录制文件：{args.replay_file}，先用 --mode record 录一次", file=sys.stderr)
            return 2
        if recording.get("input_sha") != sha:
            print("录制与当前用例输入不一致（用例改过），请重新录制", file=sys.stderr)
            return 2
        llm = ReplayClient(recording)
    else:
        load_env_file()
        missing = [k for k in ("AGENT_LLM_API_KEY", "AGENT_LLM_MODEL") if not os.environ.get(k)]
        if missing:
            print(f"缺少 LLM 配置：{', '.join(missing)}（环境变量或 {ENV_FILE}）", file=sys.stderr)
            return 2
        llm = OpenAIClient()
        if args.mode == "record":
            llm = RecordingClient(llm)

    out = run_agent(messages, ctx=ctx, source=FixtureSource(ctx), llm=llm)
    out.meta["mode"] = args.mode

    if isinstance(llm, RecordingClient):
        args.replay_file.parent.mkdir(parents=True, exist_ok=True)
        args.replay_file.write_text(
            json.dumps(llm.recording(sha), ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
        )

    print(out.model_dump_json())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
