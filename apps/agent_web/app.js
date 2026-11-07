// 软帮手智能助手 · 独立对话页。
// 只调用四个后端接口：/auth/public-key + /auth/auto-login（登录）、/agent/chat（对话）、/auth/logout（退出）。
// 会话 id 只存 sessionStorage：关掉标签页即失效，不落长期凭证。
(() => {
  "use strict";

  const $ = (s) => document.querySelector(s);
  const params = new URLSearchParams(location.search);
  const API_BASE = (params.get("api") || "http://127.0.0.1:8000").replace(/\/+$/, "");
  const STORE_KEY = "gzus.agent.session";
  const SUGGESTIONS = ["我上学期成绩怎么样", "下周三有什么课", "宿舍还剩多少电", "期末考试安排有通知吗"];
  const SPAN_LABELS = {
    plan: "规划", tool_call: "工具调用", observation: "工具返回", retrieve: "知识检索",
    generate: "生成回答", guardrail: "护栏",
  };

  const state = {
    session: null, // {sessionId, studentName, studentId}
    messages: [], // 发给后端的对话历史 {role, content}
    entries: [], // 页面上的气泡 {role, text, spans, latencyMs, failed}
    conversationId: null,
    sending: false,
  };

  // ------------------------------------------------------------ 存取

  function loadSession() {
    try {
      return JSON.parse(sessionStorage.getItem(STORE_KEY) || "null");
    } catch {
      return null;
    }
  }

  function saveSession(value) {
    try {
      if (value) sessionStorage.setItem(STORE_KEY, JSON.stringify(value));
      else sessionStorage.removeItem(STORE_KEY);
    } catch {
      /* 隐私模式：只在内存里保持登录 */
    }
  }

  async function api(path, { method = "GET", body, auth = true } = {}) {
    const headers = { "Content-Type": "application/json" };
    if (auth && state.session) headers["X-Session-Id"] = state.session.sessionId;
    let response;
    try {
      response = await fetch(`${API_BASE}${path}`, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch {
      throw Object.assign(new Error(`连不上服务（${API_BASE}），请确认后端已启动`), { status: 0 });
    }
    let payload = null;
    try {
      payload = await response.json();
    } catch {
      /* 非 JSON 响应 */
    }
    if (!response.ok) {
      const detail = payload?.detail;
      const message = typeof detail === "string" ? detail : detail?.message || `请求失败（HTTP ${response.status}）`;
      throw Object.assign(new Error(message), { status: response.status });
    }
    return payload;
  }

  // ------------------------------------------------------------ 登录

  async function login(account, password) {
    const key = await api("/auth/public-key", { auth: false });
    const body = {
      account,
      encryptedPassword: window.GzusRsa.encryptPkcs1(password, key.publicKey),
      keyId: key.keyId,
    };
    return api("/auth/auto-login", { method: "POST", body, auth: false });
  }

  function showLogin(message = "") {
    $("#chatView").hidden = true;
    $("#loginView").hidden = false;
    $("#apiBase").textContent = API_BASE;
    const err = $("#loginError");
    err.hidden = !message;
    err.textContent = message;
    $("#account").focus();
  }

  function showChat() {
    $("#loginView").hidden = true;
    $("#chatView").hidden = false;
    $("#whoami").textContent = `${state.session.studentName || "同学"} · ${state.session.studentId || ""}`;
    render();
    $("#input").focus();
  }

  $("#loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const btn = $("#loginBtn");
    btn.disabled = true;
    btn.textContent = "登录中…";
    try {
      const res = await login($("#account").value.trim(), $("#password").value);
      state.session = { sessionId: res.sessionId, studentName: res.studentName, studentId: res.studentId };
      saveSession(state.session);
      $("#password").value = "";
      resetConversation();
      showChat();
    } catch (error) {
      showLogin(error.message);
    } finally {
      btn.disabled = false;
      btn.textContent = "登录";
    }
  });

  $("#logoutBtn").addEventListener("click", async () => {
    try {
      await api("/auth/logout", { method: "POST", body: {} });
    } catch {
      /* 会话已失效也照样退出 */
    }
    state.session = null;
    saveSession(null);
    resetConversation();
    showLogin();
  });

  // ------------------------------------------------------------ 对话

  function resetConversation() {
    state.messages = [];
    state.entries = [];
    state.conversationId = null;
  }

  $("#newChatBtn").addEventListener("click", () => {
    if (state.sending) return;
    resetConversation();
    render();
    $("#input").focus();
  });

  async function send(text) {
    const content = text.trim();
    if (!content || state.sending) return;
    state.sending = true;
    state.messages.push({ role: "user", content });
    state.entries.push({ role: "user", text: content });
    render();
    try {
      const res = await api("/agent/chat", {
        method: "POST",
        body: { messages: state.messages, ...(state.conversationId ? { conversationId: state.conversationId } : {}) },
      });
      state.conversationId = res.conversationId;
      state.messages.push({ role: "assistant", content: res.answer });
      state.entries.push({ role: "assistant", text: res.answer, spans: res.spans || [], latencyMs: res.latencyMs, status: res.status });
    } catch (error) {
      state.messages.pop(); // 失败的这轮不进历史，重发时不会重复
      if (error.status === 401) {
        state.session = null;
        saveSession(null);
        resetConversation();
        state.sending = false;
        showLogin(`${error.message}，请重新登录`);
        return;
      }
      const hint = {
        404: "（后端没有开启智能体：启动时需设置 AGENT_ENABLED=true）",
        503: "（后端未配置模型：检查 services/api/.env.agent）",
      }[error.status] || "";
      state.entries.push({ role: "assistant", text: `${error.message}${hint}`, failed: true, retry: content });
    } finally {
      state.sending = false;
      render();
    }
  }

  $("#composer").addEventListener("submit", (e) => {
    e.preventDefault();
    const input = $("#input");
    const text = input.value;
    input.value = "";
    autosize();
    send(text);
  });

  $("#input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      $("#composer").requestSubmit();
    }
  });

  function autosize() {
    const input = $("#input");
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
  }
  $("#input").addEventListener("input", autosize);

  $("#traceToggle").addEventListener("change", render);

  $("#messages").addEventListener("click", (e) => {
    const retry = e.target.closest("[data-retry]");
    if (retry) {
      const index = Number(retry.dataset.retry);
      const entry = state.entries[index];
      state.entries.splice(index - 1, 2); // 去掉失败那轮的提问与报错，重新发
      send(entry.retry);
    }
    const chip = e.target.closest("[data-suggest]");
    if (chip) send(chip.dataset.suggest);
  });

  // ------------------------------------------------------------ 渲染

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  // 只支持回答里会出现的几种 Markdown：标题、加粗、行内代码、列表、表格、链接；先转义再加标签
  function inline(text) {
    return escapeHtml(text)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(https?:\/\/[^\s<）)」]+)/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>');
  }

  function markdown(src) {
    const lines = String(src || "").replace(/\r/g, "").split("\n");
    const out = [];
    let i = 0;
    const isRow = (l) => /^\s*\|.*\|\s*$/.test(l);
    const cells = (l) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    while (i < lines.length) {
      const line = lines[i];
      if (isRow(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
        const head = cells(line);
        i += 2;
        const rows = [];
        while (i < lines.length && isRow(lines[i])) rows.push(cells(lines[i++]));
        out.push(`<div class="table-wrap"><table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`);
        continue;
      }
      const ul = /^\s*[-*]\s+(.*)$/;
      const ol = /^\s*\d+[.)]\s+(.*)$/;
      if (ul.test(line) || ol.test(line)) {
        const re = ul.test(line) ? ul : ol;
        const tag = re === ul ? "ul" : "ol";
        const items = [];
        while (i < lines.length && re.test(lines[i])) items.push(lines[i++].match(re)[1]);
        out.push(`<${tag}>${items.map((t) => `<li>${inline(t)}</li>`).join("")}</${tag}>`);
        continue;
      }
      const h = line.match(/^(#{1,4})\s+(.*)$/);
      if (h) {
        out.push(`<p class="md-h">${inline(h[2])}</p>`);
      } else if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) {
        out.push("<hr>");
      } else if (line.trim()) {
        const para = [line];
        while (i + 1 < lines.length && lines[i + 1].trim() && !isRow(lines[i + 1]) && !ul.test(lines[i + 1]) && !ol.test(lines[i + 1]) && !/^#{1,4}\s/.test(lines[i + 1])) {
          para.push(lines[++i]);
        }
        out.push(`<p>${para.map(inline).join("<br>")}</p>`);
      }
      i += 1;
    }
    return out.join("");
  }

  function latency(ms) {
    if (ms === null || ms === undefined) return "";
    return ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms)}ms`;
  }

  function spanLine(span) {
    const label = SPAN_LABELS[span.span] || span.span;
    let detail = "";
    if (span.span === "plan") detail = span.intent || "";
    else if (span.span === "tool_call") {
      const args = Object.entries(span.args || {}).map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`).join(", ");
      detail = `${span.name}(${args})${span.schema_ok === false ? " · 参数不合法" : ""}`;
    } else if (span.span === "observation") detail = span.ok ? `正常${span.row_count != null ? ` · ${span.row_count} 行` : ""}` : `报错：${span.error || "未知"}`;
    else if (span.span === "retrieve") detail = `「${span.query}」命中 ${(span.chunk_ids || []).length} 条`;
    else if (span.span === "guardrail") detail = span.triggered ? `${span.action} · ${span.rule || ""}` : "放行";
    else if (span.span === "generate") detail = `引用 ${(span.citations || []).length} 条`;
    const bad = (span.span === "observation" && !span.ok) || (span.span === "tool_call" && span.schema_ok === false) || (span.span === "guardrail" && span.triggered);
    return `<li class="${bad ? "is-bad" : ""}"><b>${escapeHtml(label)}</b><span>${escapeHtml(detail)}</span><i>${latency(span.latency_ms)}</i></li>`;
  }

  function entryHtml(entry, index) {
    if (entry.role === "user") return `<div class="msg user"><div class="bubble">${escapeHtml(entry.text).replace(/\n/g, "<br>")}</div></div>`;
    if (entry.failed) {
      return `<div class="msg agent"><div class="bubble is-error"><p>${escapeHtml(entry.text)}</p>${entry.retry ? `<button type="button" class="ghost small" data-retry="${index}">重试</button>` : ""}</div></div>`;
    }
    const spans = entry.spans || [];
    const showTrace = $("#traceToggle").checked;
    const tools = spans.filter((s) => s.span === "tool_call").length;
    return `
      <div class="msg agent">
        <div class="bubble">
          <div class="md">${markdown(entry.text)}</div>
          <div class="meta">
            <span>${latency(entry.latencyMs)}${tools ? ` · 查了 ${tools} 次数据` : ""}${entry.status && entry.status !== "ok" ? ` · ${escapeHtml(entry.status)}` : ""}</span>
          </div>
          ${spans.length ? `<details class="trace" ${showTrace ? "open" : ""}><summary>执行链路 · ${spans.length} 步</summary><ol>${spans.map(spanLine).join("")}</ol></details>` : ""}
        </div>
      </div>`;
  }

  function render() {
    const box = $("#messages");
    if (!state.entries.length) {
      box.innerHTML = `
        <div class="empty">
          <h2>你好，${escapeHtml(state.session?.studentName || "同学")}</h2>
          <p>我可以帮你查自己的课表、成绩、考勤、考试安排、宿舍水电和学校通知。</p>
          <div class="chips">${SUGGESTIONS.map((s) => `<button type="button" class="chip" data-suggest="${escapeHtml(s)}">${escapeHtml(s)}</button>`).join("")}</div>
        </div>`;
    } else {
      box.innerHTML = state.entries.map(entryHtml).join("")
        + (state.sending ? '<div class="msg agent"><div class="bubble typing"><span></span><span></span><span></span></div></div>' : "");
    }
    $("#suggestions").innerHTML = state.entries.length && !state.sending
      ? SUGGESTIONS.map((s) => `<button type="button" class="chip" data-suggest="${escapeHtml(s)}">${escapeHtml(s)}</button>`).join("")
      : "";
    $("#suggestions").onclick = (e) => {
      const chip = e.target.closest("[data-suggest]");
      if (chip) send(chip.dataset.suggest);
    };
    $("#sendBtn").disabled = state.sending;
    box.scrollTop = box.scrollHeight;
  }

  // ------------------------------------------------------------ 启动

  state.session = loadSession();
  if (state.session) showChat();
  else showLogin();
})();
