import json

from fastapi.testclient import TestClient

from app.agent.llm import REPLAY_FORMAT, ReplayClient
from app.config import get_settings
from app.main import create_app
from app.routes import agent as agent_route

DEMO_ACCOUNT = "demo_screenshot_2026"
DEMO_PASSWORD = "Demo-Only-2026!"


def _reply(content=None, calls=()):
    return {
        "content": content,
        "tool_calls": [
            {"id": f"c{i}", "name": n, "arguments": json.dumps(a)} for i, (n, a) in enumerate(calls)
        ],
        "prompt_tokens": 1,
        "completion_tokens": 1,
        "latency_ms": 10.0,
    }


def _setup(monkeypatch, tmp_path, *, enabled=True):
    monkeypatch.setenv("DEBUG", "true")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "true")
    monkeypatch.setenv("DEMO_ACCOUNT", DEMO_ACCOUNT)
    monkeypatch.setenv("DEMO_PASSWORD", DEMO_PASSWORD)
    monkeypatch.setenv("AGENT_ENABLED", "true" if enabled else "false")
    get_settings.cache_clear()
    monkeypatch.setattr(agent_route, "TRACE_DIR", tmp_path)
    monkeypatch.setattr(
        agent_route,
        "make_llm",
        lambda: ReplayClient({
            "format": REPLAY_FORMAT, "model": "scripted", "input_sha": "-",
            "replies": [_reply(calls=[("get_card_balance", {})]), _reply(content="电费还剩 68.4 度。")],
        }),
    )


def _login(client):
    login = client.post("/auth/auto-login", json={"account": DEMO_ACCOUNT, "password": DEMO_PASSWORD})
    return {"X-Session-Id": login.json()["sessionId"]}


def test_chat_answers_and_writes_agentlens_trace(monkeypatch, tmp_path):
    _setup(monkeypatch, tmp_path)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/agent/chat",
            headers=_login(client),
            json={"messages": [{"role": "user", "content": "电费还剩多少"}], "conversationId": "c1"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["answer"] == "电费还剩 68.4 度。" and body["turn"] == 1
    assert [s["span"] for s in body["spans"]] == ["tool_call", "observation", "generate"]

    (trace_file,) = tmp_path.glob("*.jsonl")
    trace = json.loads(trace_file.read_text(encoding="utf-8"))
    assert trace["conversation_id"] == "c1" and trace["case_id"] == "c1#1"
    assert trace["adapter"] == "onegzus" and trace["schema_version"] == "0.2"
    assert trace["meta"]["input"] == [{"role": "user", "content": "电费还剩多少"}]
    assert trace["meta"]["account"] == "demo"


def test_chat_is_hidden_when_disabled(monkeypatch, tmp_path):
    _setup(monkeypatch, tmp_path, enabled=False)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/agent/chat", headers=_login(client), json={"messages": [{"role": "user", "content": "hi"}]},
        )
    assert resp.status_code == 404


def _as_real_session(client, monkeypatch, headers, academic):
    # 把会话改成真实账号：会话存储每次 get 都重新加载，所以替换 get 本身
    session = client.app.state.sessions.get(headers["X-Session-Id"], touch=False)
    session.is_demo = False
    session.client = academic
    session.ehall_client = None
    session.student_account = "S2026001"
    monkeypatch.setattr(client.app.state.sessions, "get", lambda *a, **k: session)


class _RealAcademic:
    def get_grades(self, year, term):
        return [{"courseName": "数据结构", "score": "88", "credit": "4", "term": f"{year}-{int(year) + 1}-{term}"}]


def test_real_session_queries_school_source_and_marks_trace(monkeypatch, tmp_path):
    _setup(monkeypatch, tmp_path)
    monkeypatch.setattr(
        agent_route,
        "make_llm",
        lambda: ReplayClient({
            "format": REPLAY_FORMAT, "model": "scripted", "input_sha": "-",
            "replies": [_reply(calls=[("get_grades", {"year": "2025", "term": "2"})]), _reply(content="数据结构 88 分。")],
        }),
    )
    with TestClient(create_app()) as client:
        headers = _login(client)
        _as_real_session(client, monkeypatch, headers, _RealAcademic())
        resp = client.post("/agent/chat", headers=headers, json={"messages": [{"role": "user", "content": "上学期成绩"}]})
    assert resp.status_code == 200
    obs = next(s for s in resp.json()["spans"] if s["span"] == "observation")
    assert obs["ok"] and obs["row_count"] == 1
    (trace_file,) = tmp_path.glob("*.jsonl")
    assert json.loads(trace_file.read_text(encoding="utf-8"))["meta"]["account"] == "real"


def test_real_session_without_school_client_must_relogin(monkeypatch, tmp_path):
    _setup(monkeypatch, tmp_path)
    with TestClient(create_app()) as client:
        headers = _login(client)
        _as_real_session(client, monkeypatch, headers, None)
        resp = client.post("/agent/chat", headers=headers, json={"messages": [{"role": "user", "content": "hi"}]})
    assert resp.status_code == 401
