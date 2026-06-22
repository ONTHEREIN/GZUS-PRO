# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

软帮手（OneGZUS，GZUS-PRO）— 广州软件学院教务助手。Flutter 前端 + FastAPI 后端，覆盖课表/成绩/考勤/水电费/请假/考试提醒。用户界面、commit message 和代码注释均为简体中文。

## Build / test / lint commands

### Flutter 前端 (`apps/mobile_web/`)

```bash
flutter pub get
flutter run -d chrome                           # 本地开发
flutter build web --dart-define=API_BASE_URL=... --no-web-resources-cdn
flutter build apk --dart-define=API_BASE_URL=...
```

- `API_BASE_URL` 默认值为 `https://onegzus.cc.cd/api,https://onegzus-onweb.pages.dev/api`（逗号分隔的 fallback 列表）。
- Android 模拟器上 `localhost`/`127.0.0.1` 会自动重写为 `10.0.2.2`。
- `build_deploy.ps1` 自动递增 `pubspec.yaml` 中的 build number 并通过 ADB 安装。使用 `-Local` 走局域网 API，`-Cloud`（默认）走生产环境。

### API 后端 (`services/api/`)

```bash
python -m venv .venv && .venv\Scripts\activate     # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload --reload-dir app --reload-exclude .venv --host 0.0.0.0

# 测试（无需外部服务 — 使用内存 SQLite）
pytest

# Lint
ruff check .
```

- Windows 本地开发使用上面的窄监听命令；裸 `uvicorn --reload` 可能扫描 `.venv`/工具链目录导致启动和重载很慢。
- 测试通过 `conftest.py` 自动设置 `DEBUG=true`、`DATABASE_URL=sqlite:///:memory:` 和虚拟 `CREDENTIAL_ENCRYPTION_KEY`。
- `test_api.py` 和 `test_login.py` 是**手动**集成测试，需要真实学校凭证（环境变量 `GZUS_TEST_ACCOUNT`/`GZUS_TEST_PASSWORD`），不在 `pytest` 默认运行范围内。

### CI/CD（全部在 push 到 `master` 时触发）

| Workflow | 触发条件 | 操作 |
|---|---|---|
| `deploy-frontend.yml` | 任意 push | Flutter 3.44.0 → `build web` → Cloudflare Pages (`onegzus-onweb` + `onegzus`) |
| `deploy-api.yml` | `services/api/**` 变更 | `npx vercel --prod` |
| `deploy-cloudflare-pages.yml` | 任意 push | 部署 `website/` 到 `intro-onegzus` |

## Architecture

```
apps/mobile_web/          Flutter 3.x app (Web + Android + iOS)
services/api/             FastAPI backend (Python 3.11+)
website/                  Static intro site (Cloudflare Pages)
tools/                    Standalone helper scripts
```

### Request flow（关键）

1. Flutter 应用调用 `API_BASE_URL`（编译时 `--dart-define`）。
2. 在 Cloudflare Pages 上，**Worker**（`apps/mobile_web/web/_worker.js`，约 1650 行）拦截请求：
   - `POST /auth/auto-login`、`POST /auth/relogin`、`GET /health` → 在边缘节点处理（CAS SSO 流程，含验证码 OCR）。
   - 其余所有请求 → 代理到 Vercel 后端。
3. Worker 注入 `X-Worker-Auth` 和 `Cookie` 头；API 在 `app/routes/deps.py` 中读取这些头部以重建学校会话。
4. `INTERNAL_API_KEY` 环境变量必须在 Worker 和 Vercel 之间一致，用于 `/internal/*` 端点。

### Database

- **生产环境**: PostgreSQL (Neon)。`DATABASE_URL` 必须是 `postgresql://` 连接字符串。
- **测试环境**: 内存 SQLite（`sqlite:///:memory:`）。每个测试通过 `conftest.py` 获得独立的 engine。
- **迁移**: `database.py:_ensure_columns()` 中的轻量级 `ALTER TABLE ADD COLUMN`。无迁移框架。
- 出于安全考虑，基于文件的 SQLite 数据库在启动时会被明确拒绝。

### Backend key files (`services/api/app/`)

| 文件 | 用途 |
|---|---|
| `main.py` | 应用入口 — 创建 FastAPI，注册中间件、路由和生命周期 |
| `config.py` | Pydantic Settings，包含所有环境变量 |
| `database.py` | SQLAlchemy 模型和 engine 管理 |
| `routes/deps.py` | 依赖注入（Worker 会话恢复、认证） |
| `school_client.py` | 学校门户客户端（JWXT 教务系统）— 最大文件，约 85KB |
| `ehall_client.py` | ehall（一站式服务）客户端 |
| `ecard_client.py` | 一卡通客户端 |
| `jobs.py` | 后台轮询器（通知、考试提醒、成绩更新、水电费提醒） |
| `push.py` | Web 推送通知 |

### Flutter frontend key files (`apps/mobile_web/lib/`)

| 文件 | 用途 |
|---|---|
| `main.dart` | 主应用 — 约 530KB，包含所有页面 UI |
| `api_client.dart` | API 客户端 — 约 84KB，包含所有 API 调用 |
| `gzus_design.dart` | 设计主题/UI 组件 |
| `services_deferred.dart` | 延迟加载服务模块配置 |

### Vendored code

`services/api/app/vendor/school_sdk/` — 打过补丁的学校 SDK（教务系统）。未经检查 `school_sdk_patches.py`，切勿从上游更新。

## Conventions & quirks

- **延迟导入**: Flutter 在 `main.dart` 中对约 15 个服务模块使用 `deferred as` 进行代码拆分。使用前务必调用 `await loadLibrary()`。
- **平台桩**: `*_web.dart` / `*_io.dart` / `*_stub.dart` 文件实现平台条件逻辑。`_web.dart` 变体在 web 上运行；`_stub.dart` 是回退。
- **会话**: 存储在 PostgreSQL 中，用于无服务器冷启动恢复（`AppSessionModel`）。实时客户端对象按需重建，而非序列化。
- **速率限制**: API 上的 `slowapi` 中间件。尊重来自 Worker 的 `X-Forwarded-For`。
- **CORS**: 按来源配置。正则模式允许 `localhost`、`192.168.*` 和 `*.pages.dev`/`*.vercel.app`。
- **无 `.env`**: `.env` 已 gitignore。使用 `.env.example` 作为模板。
- **根目录截图/`.png`**: 调试产物，已 gitignore。不要提交新的。
- **生产环境要求**: `CREDENTIAL_ENCRYPTION_KEY` 是必需的（随机 32 字节字符串）。`PUBLIC_API_BASE_URL` 和 `FRONTEND_BASE_URL` 必须使用 HTTPS，除非 `DEBUG=true`。

## Key files for common tasks

| Task | File(s) |
|---|---|
| Add a new API endpoint | `services/api/app/routes/` (add route), `routes/deps.py` (auth), `main.py` (register router) |
| Modify login flow | `apps/mobile_web/web/_worker.js` (edge), `services/api/app/routes/auth.py` (backend), `services/api/app/cas_auto_login.py` |
| Change DB schema | `services/api/app/database.py` (add model + `_ensure_columns` migration) |
| Flutter UI theme | `apps/mobile_web/lib/gzus_design.dart` |
| Push notifications | `services/api/app/push.py`, `services/api/app/jobs.py`, `apps/mobile_web/lib/push_service.dart` |
| Cloudflare Worker | `apps/mobile_web/web/_worker.js` (edit), `wrangler.toml` (config) |
