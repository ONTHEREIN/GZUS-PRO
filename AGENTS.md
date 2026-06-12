# AGENTS.md — OneGZUS (GZUS-PRO)

## Project overview

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
2. On Cloudflare Pages, a **Worker** (`apps/mobile_web/web/_worker.js`, ~1780 lines) intercepts requests:
   - `POST /auth/auto-login`, `POST /auth/relogin`, `GET /health` → handled at edge (CAS SSO flow with captcha OCR, RSA decryption).
   - Everything else → proxied to the Vercel backend.
3. The Worker injects `X-Worker-Auth` and `Cookie` headers; the API reads them in `app/routes/deps.py` to reconstruct school sessions.
4. `INTERNAL_API_KEY` env var must match between Worker and Vercel for `/internal/*` endpoints (`/internal/ocr`, `/internal/decrypt-password`, `/internal/create-session`).
5. Worker uses KV namespace `SESSIONS_KV` (`wrangler.toml`) for edge-side session persistence; Vercel backend uses PostgreSQL (`AppSessionModel`) for serverless cold-start recovery.

### Database

- **Production**: PostgreSQL (Neon). `DATABASE_URL` must be a `postgresql://` connection string. File-based SQLite is explicitly rejected at startup.
- **Tests**: SQLite in-memory (`sqlite:///:memory:`). `conftest.py` sets `DEBUG=true`, `DATABASE_URL=sqlite:///:memory:`, and a dummy `CREDENTIAL_ENCRYPTION_KEY` via monkeypatch.
- **Migrations**: Lightweight `ALTER TABLE ADD COLUMN` in `database.py:_ensure_columns()`. No migration framework.

### Vendored code

`services/api/app/vendor/school_sdk/` — patched school SDK (教务系统). Do not update from upstream without checking `school_sdk_patches.py`.

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
- `build_deploy.ps1` auto-increments build number in `pubspec.yaml`, builds APK, and installs via ADB. `-Local` for LAN API, `-Cloud` (default) for production.
- `restart.ps1` at repo root kills old processes and starts both backend + Flutter Chrome dev simultaneously.

### API backend

```bash
# From services/api/
python -m venv .venv && .venv\Scripts\activate     # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload                       # local dev on :8000

# Tests (no external services — in-memory SQLite, auto-configured)
pytest

# Lint
ruff check .
```

- `pyproject.toml`: `testpaths = ["tests"]`, `asyncio_mode = "auto"`, `line-length = 100`.
- `test_api.py` and `test_login.py` are **manual** integration tests requiring `GZUS_TEST_ACCOUNT`/`GZUS_TEST_PASSWORD` env vars. Not part of default `pytest`.

### CI/CD (all triggered on push to `master`; also support `workflow_dispatch`)

| Workflow | Trigger | Action |
|---|---|---|
| `deploy-frontend.yml` | any push | Flutter 3.44.0 → `build web` → Cloudflare Pages (`onegzus-onweb` + `onegzus`) |
| `deploy-api.yml` | `services/api/**` changed | `npx vercel --prod` |
| `deploy-cloudflare-pages.yml` | any push | Deploys `website/` to `intro-onegzus` |

- Frontend CI removes `.symbols`, CanvasKit variants, and `NOTICES` from build output before deploying.
- Vercel entry point: `app/main.py` (`vercel.json`). Sets `DEBUG=false`, `JWXT_WORKER_PROXY_ORIGIN=https://onegzus.cc.cd` in production env.

## Configuration

- API config via `pydantic-settings` — reads `services/api/.env`. See `.env.example` for all keys.
- `CREDENTIAL_ENCRYPTION_KEY` **must** be set in production (random 32-byte string). Generate: `python -c "import secrets; print(secrets.token_urlsafe(32))"`. API refuses to start without it when `DEBUG=false`.
- `PUBLIC_API_BASE_URL` and `FRONTEND_BASE_URL` must use HTTPS in production (validated in `config.py`).
- `JWXT_WORKER_PROXY_ORIGIN` — routes JWXT API calls through Worker (keeping edge IP binding). Set in Vercel env, not local dev.
- `analysis_options.yaml` enforces `prefer_const_constructors` via `flutter_lints` package.
- No `.env` in repo (gitignored). Use `.env.example` as template.

## Key files for common tasks

| Task | File(s) |
|---|---|
| Add a new API endpoint | `services/api/app/routes/` (add route), `routes/deps.py` (auth), `main.py` (register router) |
| Modify login flow | `apps/mobile_web/web/_worker.js` (edge), `services/api/app/routes/auth.py` (backend), `services/api/app/cas_auto_login.py` |
| Change DB schema | `services/api/app/database.py` (add model + `_ensure_columns` migration) |
| Flutter UI theme | `apps/mobile_web/lib/gzus_design.dart` |
| Push notifications | `services/api/app/push.py`, `services/api/app/jobs.py`, `apps/mobile_web/lib/push_service.dart` |
| Cloudflare Worker | `apps/mobile_web/web/_worker.js` (edit), `wrangler.toml` (KV config) |
| Internal Worker→API bridge | `services/api/app/routes/internal.py` (`/internal/ocr`, `/internal/decrypt-password`, `/internal/create-session`) |
| WebSocket | `services/api/app/ws.py` + `ws_router`, `apps/mobile_web/lib/ws_service.dart` |
| OSS scripts | `tools/` — leave automation (`run_auto_leave_*.py`), ecard debugging (`test_ecard*.py`) |

### Backend (`services/api/app/`)

| File | Purpose |
|---|---|
| `main.py` | App entry — creates FastAPI, registers middleware, routes, lifespan. Lazy-imports `routes/internal.py` inside `create_app()` |
| `config.py` | Pydantic Settings, all env vars |
| `database.py` | SQLAlchemy models and engine management (sync session factory) |
| `routes/deps.py` | Dependency injection (Worker session recovery, auth) |
| `school_client.py` | School portal client (JWXT 教务系统) — largest file |
| `ehall_client.py` | ehall (一站式服务) client |
| `ecard_client.py` | 一卡通 client |
| `jobs.py` | Background pollers (notifications, exam reminders, grade updates, utility reminders) |
| `push.py` | Web push notifications |
| `sessions.py` | Session store (create/recover/cleanup), credential encryption (Fernet) |
| `rsa_keys.py` | RSA key manager for password decryption (Worker→API bridge) |
| `captcha_ocr.py` | Captcha OCR (ddddocr) for CAS login |
| `cache_service.py` | In-memory caches (used by jobs) |

### Frontend (`apps/mobile_web/lib/`)

| File | Purpose |
|---|---|
| `main.dart` | Main app — all page UI (~15KLOC) |
| `api_client.dart` | API client — all API calls, session management |
| `gzus_design.dart` | Design theme / UI components |
| `services_deferred.dart` | Deferred loading service module config |

## Conventions & quirks

- **Language**: All user-facing strings, commit messages, and most comments are in Chinese (Simplified) throughout.
- **Deferred imports**: Flutter uses `deferred as` for ~15 service modules in `main.dart`. Always `await loadLibrary()` before use. Batch loaded via `DeferredServices.initialize()` in `services_deferred.dart`.
- **Platform stubs**: Files ending in `_web.dart` / `_stub.dart` / `_io.dart` implement platform-conditional logic. `_web.dart` runs on web; `_stub.dart` is fallback; `_io.dart` for mobile native.
- **Sessions**: Stored in PostgreSQL (`AppSessionModel`) for serverless cold-start recovery. Live client objects rebuilt on demand, never serialized. Worker also caches in KV.
- **Rate limiting**: `slowapi` middleware on API. Respects `X-Forwarded-For` header from Workers.
- **CORS**: Configured per-origin + regex. Regex allows `localhost`, `192.168.*`, `*.pages.dev`, `*.vercel.app`.
- **Security headers**: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `HSTS` in prod. Enforced in `main.py` middleware.
- **Body limit**: 10MB max request body (enforced in middleware).
- **Screenshots/`.png` in root**: Debug artifacts, gitignored. Don't commit.
