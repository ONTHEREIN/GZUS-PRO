# AGENTS.md — 软帮手 / OneGZUS (GZUS-PRO)

University teaching-affairs assistant (课表/成绩/考勤/水电费/请假/考试提醒). Flutter frontend + FastAPI backend. Chinese-language UI throughout.

## Architecture

```
apps/mobile_web/          Flutter 3.x app (Web + Android + iOS)
services/api/             FastAPI backend (Python 3.11+), deployed to Vercel
website/                  Static intro site, deployed to Cloudflare Pages (intro-onegzus)
tools/                    Standalone helper scripts (leave automation, ecard testing)
```

### Request flow (critical)

1. Flutter app calls API at `API_BASE_URL` (compile-time `--dart-define`).
2. On Cloudflare Pages, a **Worker** (`apps/mobile_web/web/_worker.js`, ~2300 lines) intercepts requests:
   - `POST /auth/auto-login`, `POST /auth/relogin`, `GET /health` → handled at edge (CAS SSO flow with captcha OCR, RSA decryption).
   - Everything else → proxied to the Vercel backend.
3. The Worker injects `X-Worker-Auth` and `Cookie` headers; the API reads them in `app/routes/deps.py` to reconstruct school sessions.
4. `INTERNAL_API_KEY` env var must match between Worker and Vercel for `/internal/*` endpoints.
5. Worker uses KV namespace `SESSIONS_KV` (`wrangler.toml`) for edge-side session persistence; Vercel backend uses PostgreSQL (`AppSessionModel`) for serverless cold-start recovery.

### Database

- **Production**: PostgreSQL (Neon). `DATABASE_URL` must be `postgresql://`. File-based SQLite is explicitly rejected at startup (`database.py:_validate_database_url`).
- **Tests**: SQLite in-memory (`sqlite:///:memory:`). `conftest.py` autouse fixture sets `DEBUG=true`, `DATABASE_URL=sqlite:///:memory:`, `CREDENTIAL_ENCRYPTION_KEY`, `PUBLIC_API_BASE_URL`, `FRONTEND_BASE_URL` via monkeypatch, then calls `database.reset_engine()` and `get_settings.cache_clear()`.
- **Migrations**: Lightweight `ALTER TABLE ADD COLUMN` in `database.py:_ensure_columns()`. No migration framework. Add new columns there.

### Vendored code

`services/api/app/vendor/school_sdk/` — patched school SDK. Do not update from upstream without checking `school_sdk_patches.py`.

## Developer commands

### Flutter frontend

```bash
# From apps/mobile_web/
flutter pub get
flutter run -d chrome                           # local dev
flutter build web --dart-define=API_BASE_URL=... --no-web-resources-cdn
flutter build apk --dart-define=API_BASE_URL=...
```

- `API_BASE_URL` defaults to `https://onegzus.cc.cd/api,https://onegzus-onweb.pages.dev/api` (comma-separated fallback list; Vercel URLs filtered out).
- On Android, `localhost`/`127.0.0.1` is auto-rewritten to `10.0.2.2` for emulator access.
- `build_deploy.ps1` auto-increments build number in `pubspec.yaml`, builds APK, and installs via ADB. `-Local` for LAN API, `-Cloud` (default) for production. Also supports `-ApiUrl=<url>`.
- `restart.ps1` at repo root kills old processes, starts backend, waits for `/health`, then starts Flutter Chrome dev.

### API backend

```bash
# From services/api/
python -m venv .venv && .venv\Scripts\activate     # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload --reload-dir app --reload-exclude .venv --host 0.0.0.0

# Tests (no external services — in-memory SQLite, auto-configured)
pytest

# Lint
ruff check .
```

- Use the narrowed reload command above on Windows; bare `uvicorn --reload` can scan `.venv`/tooling and make local restarts very slow.
- `pyproject.toml`: `testpaths = ["tests"]`, `asyncio_mode = "auto"`, `line-length = 100`, `target-version = "py311"`.
- `test_api.py` and `test_login.py` in repo root of `services/api/` are **manual** integration tests requiring `GZUS_TEST_ACCOUNT`/`GZUS_TEST_PASSWORD` env vars. Not part of default `pytest`.

### CI/CD (all on push to `master`; also `workflow_dispatch`)

| Workflow | Trigger | Action |
|---|---|---|
| `deploy-frontend.yml` | any push | Flutter 3.44.0 → `build web` → Cloudflare Pages (`onegzus-onweb` + `onegzus`) |
| `deploy-api.yml` | `services/api/**` changed | `npx vercel --prod` |
| `deploy-cloudflare-pages.yml` | any push | Deploys `website/` to `intro-onegzus` |
| `deploy-edgeone-pages.yml` | `workflow_dispatch` only | Deploys `apps/mobile_web/web/` to EdgeOne (`onegzus-overseas`) for overseas access |
| `cron-wechat-sync.yml` | 每 6 小时 | 调 `/internal/cron/wechat-sync` 同步公众号文章（`X-Internal-Key` 鉴权） |

- Frontend CI removes `.symbols`, CanvasKit variants, and `NOTICES` from build output before deploying.
- Vercel entry point: `app/main.py` (`vercel.json`). Sets `DEBUG=false`, `JWXT_WORKER_PROXY_ORIGIN=https://onegzus.cc.cd`, `ECARD_WORKER_PROXY_ORIGIN=https://onegzus.cc.cd` in production env.

## Configuration

- API config via `pydantic-settings` — reads `services/api/.env`. See `.env.example` for all keys.
- `CREDENTIAL_ENCRYPTION_KEY` **must** be set in production (random 32-byte string). Generate: `python -c "import secrets; print(secrets.token_urlsafe(32))"`. API refuses to start without it when `DEBUG=false`.
- `PUBLIC_API_BASE_URL` and `FRONTEND_BASE_URL` must use HTTPS in production (validated in `config.py`).
- `JWXT_WORKER_PROXY_ORIGIN` and `ECARD_WORKER_PROXY_ORIGIN` — routes school API calls through Worker (keeping edge IP binding). Set in Vercel env, not local dev.
- `ADMIN_SEED_OWNER` — 管理后台首个 owner 学号（逗号分隔）。启动时幂等写入 `admin_users` 表；之后可在后台动态增删管理员。未配置则后台无管理员。
- `analysis_options.yaml` enforces `prefer_const_constructors` via `flutter_lints` package.
- No `.env` in repo (gitignored). Use `.env.example` as template.

## Key files for common tasks

| Task | File(s) |
|---|---|
| Add a new API endpoint | `services/api/app/routes/` (add route), `routes/deps.py` (auth), `main.py` (register router) |
| Modify login flow | `apps/mobile_web/web/_worker.js` (edge), `services/api/app/routes/auth.py` (backend), `services/api/app/cas_auto_login.py` |
| 管理后台（Admin） | `services/api/app/routes/admin.py`（`/admin/*`，`require_admin` 鉴权）、`admin_users`/`admin_audit_log` 表、`ADMIN_SEED_OWNER` 种子、`apps/mobile_web/lib/pages/admin/`、Worker `isAdmin` 透传 |
| Change DB schema | `services/api/app/database.py` (add model + `_ensure_columns` migration) |
| Flutter UI theme | `apps/mobile_web/lib/gzus_design.dart` |
| Push notifications | `services/api/app/push.py`, `services/api/app/jobs.py`, `apps/mobile_web/lib/push_service.dart` |
| Cloudflare Worker | `apps/mobile_web/web/_worker.js` (edit), `wrangler.toml` (KV config) |
| Internal Worker→API bridge | `services/api/app/routes/internal.py` |
| WebSocket | `services/api/app/ws.py` + `ws_router`, `apps/mobile_web/lib/ws_service.dart` |
| Leave/请假 service | `services/api/app/leave_service.py`, `routes/ehall.py` |
| Staff lookup | `services/api/app/staff_service.py` |
| Weather proxy | `services/api/app/routes/weather.py` |

### Backend (`services/api/app/`)

| File | Purpose |
|---|---|
| `main.py` | App entry — creates FastAPI, registers middleware, routes, lifespan. Lazy-imports `routes/internal.py` inside `create_app()`. Background pollers only start when `not IS_VERCEL`. |
| `config.py` | Pydantic Settings, all env vars. `@lru_cache get_settings()`. |
| `database.py` | SQLAlchemy models, engine management, `_ensure_columns()` migrations. Sync engine only. |
| `schemas.py` | Pydantic request/response models (LoginRequest, etc.) |
| `routes/deps.py` | Dependency injection (Worker cookie injection via `X-Worker-Auth`, session recovery, auth, `require_admin`) |
| `routes/admin.py` | 管理后台 `/admin/*`（总览/会话踢下线/管理员管理/推送/缓存/水电费/系统状态/审计日志 + 校历/通知上传 + 公众号文章管理）。鉴权：`Depends(require_admin)`（`session.is_admin`），owner 才能增删管理员。敏感操作写 `admin_audit_log`。`admin_role_of()` 供 `/internal/create-session` 标记 is_admin。`list_published_admin_notices()` 供 `/academic/notices` 并入「校历」类通知 |
| `wechat_service.py` | 公众号文章同步（可插拔 `WechatFetcher` 通道）：① `RssFetcher`（wechatrss 第三方 RSS，`WECHAT_RSS_URL` 含私人 token，任何日志/响应必须经 `_mask_url()` 脱敏）② `AlbumFetcher`（微信公开合集接口 appmsgalbum，匿名免凭据）。`default_fetcher()` 按 配置优先级 RSS > 合集 选通道，`active_channel()` 供管理后台展示。另含 `fetch_article_meta()`（og 元数据，粘贴链接兜底）、`sync_articles()`/`should_sync()` 惰性同步。表：`WxArticle`/`WechatSyncState` |
| `school_client.py` | School portal client (JWXT 教务系统) — HTTP client + login/session. Normalizers/notice parsing split out below. |
| `jwxt/normalizers.py` | JWXT 数据归一化纯函数 (课表/成绩/考勤/学分) — split from `school_client.py` |
| `jwxt/notice_parser.py` | 自研 HTML 节点 + 通知条目/详情提取 — split from `school_client.py` |
| `ehall_client.py` | ehall (一站式服务) client |
| `ecard_client.py` | 一卡通 client |
| `leave_service.py` | Leave/请假 business logic (section times, date ranges) |
| `staff_service.py` | Staff member lookup/sync from ehall |
| `jobs.py` | Background pollers (notifications, exam reminders, grade updates, utility reminders). Poller cache classes moved to `cache_service.py`; pollers lazy-imported in `main.py` lifespan. |
| `push.py` | Web push notifications |
| `sessions.py` | Session store (create/recover/cleanup), credential encryption (Fernet). `student_id_of()` resolves account without `get_info()`. |
| `rsa_keys.py` | RSA key manager for password decryption (Worker→API bridge) |
| `captcha_ocr.py` | Captcha OCR (ddddocr) for CAS login |
| `cache_service.py` | DB-backed cache (TTL-aware) + poller in-memory caches (NoticeCache/GradeUpdateCache/ExamReminderCache) |
| `notice_utils.py` | Notification formatting utilities + `merge_notices()` (JWXT+ehall 合并去重) |
| `rate_limit.py` | SlowAPI rate limiter configuration |

### Frontend (`apps/mobile_web/lib/`)

| File | Purpose |
|---|---|
| `main.dart` | App shell — 入口、`OneGzusApp`、`DashboardShell`(导航壳/登录/加载/侧栏/底部导航)。页面 UI 已拆到 `pages/`。 |
| `api_client.dart` | API client — all API calls, session management |
| `gzus_design.dart` | Design theme / UI components |
| `schedule_utils.dart` | 课表/日期共享工具 (`mondayOf`/`weekFromDate`/`dateText`/`scheduleTimes`/`defaultFirstWeekStart`) |
| `services_deferred.dart` | Deferred loading service module config |
| `ws_service.dart` | WebSocket client |
| `push_service.dart` | Push notification registration |
| `web_push_service.dart` | Web Push (with `_web.dart` / `_stub.dart` variants) |
| `test_flags.dart` | 测试开关 (`debugHideEcardForTests` / `hideEcardOnCurrentPlatform`)，main.dart 通过 `export` 保持兼容 |

#### 页面模块 (`lib/pages/`)
| 目录 | 页面 |
|---|---|
| `home/` | `HomePage` + 首页卡片组 + `HomeWidgetBridge`/`NotificationOpenBridge` |
| `schedule/` | `SchedulePage` + `TimetableView` 等课表组件 |
| `ecard/` | `EcardPage` 一卡通/水电费 |
| `grades/` | `GradesPage` 成绩 |
| `exams/` | `ExamsPage` 考试 |
| `attendance/` | `AttendancePage` 考勤 |
| `credits/` | `CreditsPage` 学分 |
| `notices/` | `NoticesPage` 通知 |
| `applications/` | `ApplicationsPage` 应用 |
| `business/` | `BusinessPage` 业务 |
| `info/` | `InfoPage` 个人信息 |
| `leave/` | `AutoLeavePage` 自动请假 |
| `ftp/` | `FtpUploadPage` 作业上传 |
| `more/` | `MorePage` + 关于/桌面组件引导页 |
| `admin/` | `AdminPage` 管理后台（总览/会话/管理员/数据统计/系统 + `notices_tab.dart` 校历上传 + `wechat_tab.dart` 公众号文章管理） |

#### 共享层 (`lib/widgets/` 与 `lib/models/`)
- `widgets/`：`PagePanel`/`AsyncPanel`/`PageRefresh`、`EmptyState`、`StatusPill`/`IconBadge`/`MetricPill`、`SimpleTable`/`MobileRecordCard`、`ProgressCategoryStrip` 等跨页组件
- `models/`：`NavTabConfig`/`NavPreferences`、`HomeModuleConfig`/`HomePreferences`、`GradeAttempt`/`GradeGroup` 及成绩考试共享 helper (`courseKey`/`compareExamsByTime` 等)

### API route modules (`services/api/app/routes/`)

| File | Prefix | Purpose |
|---|---|---|
| `auth.py` | `/auth` | Login, relogin, auto-login |
| `academic.py` | `/academic` | 课表/成绩/考勤 |
| `ehall.py` | `/ehall` | 请假/通知/办事大厅 |
| `ecard.py` | `/ecard` | 一卡通/水电费 |
| `push.py` | `/push` | Push notification registration |
| `weather.py` | `/weather` | Weather proxy (wttr.in) |
| `internal.py` | `/internal` | Worker→API bridge (OCR, decrypt, session). `create-session` 查 `admin_users` 标记 `is_admin` 并返回 `isAdmin`。cron 端点：`/internal/cron/ecard-reminder`、`/internal/cron/wechat-sync`（GitHub Actions 定时调用，`X-Internal-Key` 鉴权） |
| `admin.py` | `/admin` | 管理后台（会话/管理员/统计/系统状态 + 校历上传 `/admin/notices` + 公众号管理 `/admin/wechat/*`） |

## Conventions & quirks

- **Language**: All user-facing strings, commit messages, and most comments are in Chinese (Simplified) throughout.
- **Deferred imports**: Flutter uses `deferred as` for ~15 service modules in `main.dart`. Always `await loadLibrary()` before use. Batch loaded via `DeferredServices.initialize()` in `services_deferred.dart`.
- **Platform stubs**: Files ending in `_web.dart` / `_stub.dart` / `_io.dart` implement platform-conditional logic. `_web.dart` runs on web; `_stub.dart` is fallback; `_io.dart` for mobile native.
- **Sessions**: Stored in PostgreSQL (`AppSessionModel`) for serverless cold-start recovery. Live client objects rebuilt on demand, never serialized. Worker also caches in KV.
- **Rate limiting**: `slowapi` middleware on API. Respects `X-Forwarded-For` header from Workers.
- **CORS**: `allow_credentials=False` (not True). Configured per-origin + regex. Regex allows `localhost`, `192.168.*`, `*.pages.dev`, `*.vercel.app`.
- **Security headers**: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`, `HSTS` in prod.
- **Body limit**: 10MB max request body (enforced in middleware).
- **Vercel detection**: `IS_VERCEL = os.environ.get("VERCEL") == "1"`. Background pollers are skipped on Vercel (only run in local dev).
- **Screenshots/`.png` in root**: Debug artifacts, gitignored. Don't commit.
- **`config.py` uses `@lru_cache`**: After monkeypatching env vars in tests, must call `get_settings.cache_clear()` to pick up changes.
- **`database.py` global state**: Engine/session factory are module-level globals. Tests must call `database.reset_engine()` to get a fresh in-memory DB.
