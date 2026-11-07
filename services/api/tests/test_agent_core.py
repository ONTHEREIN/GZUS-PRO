import io
import json
from datetime import date

from app.agent import cli, policy
from app.agent.core import run_agent
from app.agent.datasource import AgentContext, Fault, FaultySource, FixtureSource, Period
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
    assert out.meta["current_term"] == "2026-2027-1" and out.meta["week"] == 4


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


def test_extra_notices_are_searchable_and_change_input_sha():
    ctx = AgentContext(TODAY)
    extra = [{"title": "关于奖学金评定的通知", "date": "2026-09-20", "url": "https://demo.local/x"}]
    hits = FixtureSource(ctx, extra_notices=extra).notices("奖学金").data
    assert [h.chunk_id for h in hits] == ["https://demo.local/x"]

    base = {"messages": [{"role": "user", "content": "奖学金"}]}
    assert cli.input_sha(base) != cli.input_sha({**base, "fixtures": {"extra_notices": extra}})


def test_faulty_source_error_kind_reaches_observation():
    ctx = AgentContext(TODAY)
    source = FaultySource(FixtureSource(ctx), [Fault.parse({"source": "grades", "kind": "upstream_timeout"})])
    out = run_agent(
        [{"role": "user", "content": "上学期成绩"}], ctx=ctx, source=source,
        llm=_scripted(
            _reply(calls=[("get_grades", {"year": "2025", "term": "2"})]),
            _reply(content="成绩系统超时了。"),
        ),
    )
    obs = out.spans[1]
    assert not obs.ok and obs.error == "upstream_timeout"
    # 未注入的数据源不受影响
    assert source.card_balance().ok


def test_faulty_source_patch_rewrites_only_matching_rows():
    ctx = AgentContext(TODAY)
    clean = FixtureSource(ctx).grades(Period(2025, 2)).data
    target = clean[0].course_name
    fault = Fault.parse({"source": "grades", "kind": "patch", "set": {"score": "12"},
                         "where": {"courseName": target}})
    patched = FaultySource(FixtureSource(ctx), [fault]).grades(Period(2025, 2)).data
    assert patched[0].score == "12"
    assert [g.score for g in patched[1:]] == [g.score for g in clean[1:]]


def test_faulty_source_slow_keeps_data_and_adds_latency():
    ctx = AgentContext(TODAY)
    clean = FixtureSource(ctx).grades(Period(2025, 2))
    fault = Fault.parse({"source": "grades", "kind": "slow", "latency_ms": 9000})
    slow = FaultySource(FixtureSource(ctx), [fault]).grades(Period(2025, 2))
    assert slow.ok and slow.data == clean.data
    assert slow.latency_ms >= 9000


def test_fault_spec_is_validated():
    import pytest

    for bad in ({"source": "dorm", "kind": "empty"}, {"source": "grades", "kind": "boom"},
                {"source": "grades", "kind": "patch"}, {"source": "grades", "kind": "slow"}):
        with pytest.raises(ValueError):
            Fault.parse(bad)


class _FakeSchoolClient:
    """真实教务客户端的替身：按 year/term 记录调用，可指定抛出的异常。"""

    def __init__(self, raises=None):
        self.raises = raises
        self.calls = []

    def _maybe_raise(self):
        if self.raises is not None:
            raise self.raises

    def get_grades(self, year, term):
        self.calls.append(("grades", year, term))
        self._maybe_raise()
        return [{"courseName": "数据结构", "score": "88", "credit": "4", "term": f"{year}-{int(year) + 1}-{term}"}]

    def get_schedule(self, year, term):
        self.calls.append(("schedule", year, term))
        self._maybe_raise()
        return [
            {"name": "操作系统", "weekday": 1, "startSection": 1, "endSection": 2, "weeks": "1-8"},
            {"name": "编译原理", "weekday": 2, "startSection": 3, "endSection": 4, "weeks": "9-16"},
        ]

    def get_notices(self):
        self._maybe_raise()
        return [{"category": "教务通知", "title": "期末考试安排", "date": "2026-09-12", "url": "https://x/exam"}]


def test_school_source_queries_session_client_by_period():
    from app.agent.datasource import SchoolSource

    ctx = AgentContext(TODAY)
    client = _FakeSchoolClient()
    source = SchoolSource(ctx, client, None, "S001")
    grades = source.grades(Period(2025, 2))
    assert grades.ok and [g.course_name for g in grades.data] == ["数据结构"]
    schedule = source.schedule(None)  # 第 4 周：只剩 1-8 周的课
    assert [c.name for c in schedule.data] == ["操作系统"]
    assert client.calls == [("grades", "2025", "2"), ("schedule", "2026", "1")]
    hits = source.notices("考试安排").data
    assert hits and hits[0].chunk_id == "https://x/exam"


def test_school_source_maps_upstream_failures_to_error_kinds():
    import httpx

    from app.agent.datasource import SchoolSource
    from app.school_client import AuthenticationError

    ctx = AgentContext(TODAY)
    cases = {
        AuthenticationError("expired"): "auth_expired",
        httpx.ReadTimeout("slow"): "upstream_timeout",
        NotImplementedError(): "not_implemented",
        RuntimeError("boom"): "upstream_error",
    }
    for exc, kind in cases.items():
        result = SchoolSource(ctx, _FakeSchoolClient(raises=exc), None, "S001").grades(Period(2025, 2))
        assert not result.ok and result.error_kind == kind and result.data is None
