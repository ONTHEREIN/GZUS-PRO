# 软帮手 · 智能助手（独立网页）

从 Flutter 应用里拆出来的智能体对话页：纯静态 HTML/JS，无构建、无第三方依赖。
登录沿用后端同一套接口，密码与 Flutter 端一样用 RSA（PKCS#1 v1.5）加密后提交。

| 用途 | 接口 |
|---|---|
| 登录 | `GET /auth/public-key` → `POST /auth/auto-login` |
| 对话 | `POST /agent/chat`（请求头 `X-Session-Id`） |
| 退出 | `POST /auth/logout` |

## 本地运行

```bash
# 1. 后端（演示模式 + 打开智能体；模型配置读 services/api/.env.agent）
cd services/api
DEBUG=true DATABASE_URL=sqlite:///:memory: CREDENTIAL_ENCRYPTION_KEY=local-demo-key \
  DEMO_ACCOUNT_ENABLED=true DEMO_PASSWORD=<本地演示密码> AGENT_ENABLED=true \
  .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000

# 2. 页面
python3 -m http.server 5181 --bind 127.0.0.1 -d apps/agent_web
# → http://127.0.0.1:5181   后端不在 8000 时：http://127.0.0.1:5181/?api=http://127.0.0.1:9000
```

- 智能体只对演示账号开放（后端 `/agent/chat` 对非演示会话返回 403）。
- 会话 id 只存在 `sessionStorage`，关掉标签页即失效。
- 每轮对话照常写入 `services/api/data/traces/`，AgentLens 审计台「线上对话」可直接审计。
- 仅本地演示，不部署。
