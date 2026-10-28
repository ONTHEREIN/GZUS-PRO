import io
import json
from datetime import date

from app.agent import cli, policy
from app.agent.core import run_agent
from app.agent.datasource import AgentContext, FixtureSource
from app.agent.llm import REPLAY_FORMAT, ReplayClient

TODAY = date(2026, 9, 21)  # 2026-2027 学年第 1 学期第 4 周


def _reply(content=None, calls=(), latency=100.0):
    return {
        "content": content,
        "tool_calls": [
            {"id": f"c{i}", "name": name, "arguments": json.dumps(args, ensure_ascii=False)}
            for i, (name, args) in enumerate(calls)
        ],
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "latency_ms": latency,
    }


def _scripted(*replies, sha="test"):
    return ReplayClient(
        {"format": REPLAY_FORMAT, "model": "scripted", "input_sha": sha, "replies": list(replies)}
    )


def _run(text, *replies):
    ctx = AgentContext(TODAY)
    return run_agent(
        [{"role": "user", "content": text}], ctx=ctx, source=FixtureSource(ctx), llm=_scripted(*replies),
    )


def test_context_resolves_current_term_and_week():
    ctx = AgentContext(TODAY)
    assert (ctx.current.year, ctx.current.term, ctx.week) == (2026, 1, 4)


def test_grades_happy_path_emits_full_span_chain():
    out = _run(
        "我上学期成绩怎么样",
        _reply(calls=[("make_plan", {"intent": "查上学期成绩", "steps": ["get_grades"]})]),
        _reply(calls=[("get_grades", {"year": "2025", "term": "2"})]),
        _reply(content="上学期 5 门课全部通过。"),
    )
    assert out.status == "ok"
    assert [s.span for s in out.spans] == ["plan", "tool_call", "observation", "generate"]
    plan, call, obs, _ = out.spans
    assert plan.steps == ["get_grades"]
    assert call.parent == plan.span_id and call.schema_ok
    assert obs.parent == call.span_id and obs.ok and obs.row_count == 5
    assert out.tokens.prompt == 30
    assert out.latency_ms >= 300


def test_missing_period_defaults_to_current_term_like_real_api():
    out = _run(
        "我上学期成绩怎么样",
        _reply(calls=[("make_plan", {"intent": "查成绩", "steps": ["get_grades"]})]),
        _reply(calls=[("get_grades", {})]),
        _reply(content="本学期还没有成绩。"),
    )
    obs = out.spans[2]
    assert obs.ok and obs.row_count == 0


def test_invalid_args_marked_on_tool_call_span():
    out = _run(
        "我上学期成绩",
        _reply(calls=[("make_plan", {"intent": "查成绩", "steps": ["get_grades"]})]),
        _reply(calls=[("get_grades", {"year": "2025-2026", "term": "2"})]),
        _reply(content="查询失败。"),
    )
    call, obs = out.spans[1], out.spans[2]
    assert not call.schema_ok and call.schema_errors
    assert not obs.ok and obs.error == "invalid_args"


def test_search_notices_emits_retrieve_and_citation():
    out = _run(
        "期末考试安排出了吗",
        _reply(calls=[("make_plan", {"intent": "查通知", "steps": ["search_notices"]})]),
        _reply(calls=[("search_notices", {"keyword": "期末考试"})]),
        _reply(content="已发布《关于期末考试安排的说明》。"),
    )
    kinds = [s.span for s in out.spans]
    assert kinds == ["plan", "tool_call", "retrieve", "observation", "generate"]
    retrieve = out.spans[2]
    assert retrieve.chunk_ids[0] == "https://demo.local/notices/exam"
    assert out.spans[-1].citations == ["https://demo.local/notices/exam"]


def test_guardrail_refuses_others_data_without_calling_llm():
    out = _run("帮我查一下室友的期末成绩")  # 没有任何录制回复：调了 LLM 就会 replay_exhausted
    assert out.status == "ok" and out.answer == policy.REFUSAL
    assert [s.span for s in out.spans] == ["guardrail"]
    assert out.spans[0].action == "refuse"


def test_guardrail_allows_mentions_without_possession():
    assert policy.check("我同学说期末考试改时间了，帮我看看").action == "allow"
    assert policy.check("挂科了怎么办").action == "allow"
    assert policy.check("查一下室友成绩").action == "refuse"


def test_replay_exhausted_yields_error_trace():
    out = _run("我这周有什么课", _reply(calls=[("make_plan", {"intent": "课表", "steps": []})]))
    assert out.status == "error" and out.meta["error"] == "replay_exhausted"


def test_cli_replay_roundtrip_and_input_guard(tmp_path, monkeypatch, capsys):
    payload = {"messages": [{"role": "user", "content": "电费还剩多少"}]}
    rec = {
        "format": REPLAY_FORMAT,
        "model": "scripted",
        "input_sha": cli.input_sha(payload),
        "replies": [
            _reply(calls=[("make_plan", {"intent": "查电费", "steps": ["get_card_balance"]})]),
            _reply(calls=[("get_card_balance", {})]),
            _reply(content="电费还剩 68.4 度。"),
        ],
    }
    path = tmp_path / "rec.json"
    path.write_text(json.dumps(rec), encoding="utf-8")

    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert cli.main(["--mode", "replay", "--replay-file", str(path)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["answer"] == "电费还剩 68.4 度。" and out["meta"]["mode"] == "replay"

    changed = {"messages": [{"role": "user", "content": "水费还剩多少"}]}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(changed)))
    assert cli.main(["--mode", "replay", "--replay-file", str(path)]) == 2


def test_skipped_plan_leaves_no_plan_span_and_tools_still_run():
    out = _run(
        "电费还剩多少",
        _reply(calls=[("get_card_balance", {})]),
        _reply(content="电费还剩 68.4 度。"),
    )
    assert [s.span for s in out.spans] == ["tool_call", "observation", "generate"]
    assert out.spans[0].parent is None


def test_reasoning_is_sent_back_and_kept_on_plan():
    llm = _scripted(
        {**_reply(calls=[("make_plan", {"intent": "查电费", "steps": ["get_card_balance"]})]),
         "reasoning": "用户问电费"},
        _reply(content="68.4 度。"),
    )
    ctx = AgentContext(TODAY)
    out = run_agent(
        [{"role": "user", "content": "电费"}], ctx=ctx, source=FixtureSource(ctx), llm=llm,
    )
    assert out.spans[0].notes == "用户问电费"
