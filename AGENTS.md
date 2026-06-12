# AGENTS.md — OneGZUS (GZUS-PRO)

## Project overview

University teaching-affairs assistant (课表/成绩/考勤/水电费/请假/考试提醒). Flutter frontend + FastAPI backend. Chinese-language UI throughout.

## Architecture

```
apps/mobile_web/          Flutter 3.x app (Web + Android + iOS)
services/api/             FastAPI backend (Python 3.11+)
website/                  Static intro site (deployed to Cloudflare Pages)
tools/                    Standalone helper scripts (leave automation)
```

### Request flow (critical)

1. Flutter app calls API at `API_BASE_URL` (compile-time `--dart-define`).
2. On Cloudflare Pages, a **Worker** (`apps/mobile_web/web/_worker.js`, ~1650 lines) intercepts requests:
   - `POST /auth/auto-login`, `POST /auth/relogin`, `GET /health` → handled at edge (CAS SSO flow with captcha OCR).
   - Everything else → proxied to the Vercel backend.
3. The Worker injects `X-Worker-Auth` and `Cookie` headers; the API reads them in `app/routes/deps.py` to reconstruct school sessions.
4. `INTERNAL_API_KEY` env var must match between Worker and Vercel for `/internal/*` endpoints.

### Database

- **Production**: PostgreSQL (Neon). Required — `DATABASE_URL` must be a `postgresql://` connection string.
- **Tests**: SQLite in-memory (`sqlite:///:memory:`). Each test gets a fresh engine via `conftest.py`.
- **Migrations**: Lightweight `ALTER TABLE ADD COLUMN` in `database.py:_ensure_columns()`. No migration framework.
- SQLite file databases are explicitly rejected at startup (security: no local user data files).

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

- `API_BASE_URL` defaults to `https://onegzus.cc.cd/api,https://onegzus-onweb.pages.dev/api` (comma-separated fallback list; Vercel URLs are filtered out).
- On Android, `localhost`/`127.0.0.1` is auto-rewritten to `10.0.2.2` for emulator access.
- `build_deploy.ps1` auto-increments the build number in `pubspec.yaml` and installs APK via ADB. Use `-Local` for LAN API, `-Cloud` (default) for production.

### API backend

```bash
# From services/api/
python -m venv .venv && .venv\Scripts\activate     # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload                       # local dev on :8000

# Tests (no external services needed — uses in-memory SQLite)
pytest

# Lint
ruff check .
```

- Tests set `DEBUG=true`, `DATABASE_URL=sqlite:///:memory:`, and a dummy `CREDENTIAL_ENCRYPTION_KEY` automatically via `conftest.py`.
- `test_api.py` and `test_login.py` are **manual** integration tests requiring real school credentials (`GZUS_TEST_ACCOUNT`/`GZUS_TEST_PASSWORD` env vars). Not part of `pytest`.
- `pyproject.toml` configures pytest: `testpaths = ["tests"]`, `asyncio_mode = "auto"`.

### CI/CD (all triggered on push to `master`; also support `workflow_dispatch`)

| Workflow | Trigger | What it does |
|---|---|---|
| `deploy-frontend.yml` | any push | Flutter 3.44.0 → `build web` → Cloudflare Pages (`onegzus-onweb` + `onegzus`) |
| `deploy-api.yml` | `services/api/**` changed | `npx vercel --prod` |
| `deploy-cloudflare-pages.yml` | any push | Deploys `website/` to `intro-onegzus` |

## Configuration

- API config via `pydantic-settings` — reads `services/api/.env`. See `.env.example` for all keys.
- `CREDENTIAL_ENCRYPTION_KEY` **must** be set in production (random 32-byte string). The API refuses to start without it when `DEBUG=false`.
- `PUBLIC_API_BASE_URL` and `FRONTEND_BASE_URL` must use HTTPS in production.
- Flutter build-time config: `API_BASE_URL` via `--dart-define`.
- `analysis_options.yaml` enforces `prefer_const_constructors`.

## Conventions & quirks

- **Language**: All user-facing strings, commit messages, and most code comments are in Chinese (Simplified).
- **Deferred imports**: Flutter uses `deferred as` for code splitting ~15 service modules in `main.dart`. Always `await loadLibrary()` before use.
- **Platform stubs**: Files like `ics_download.dart` / `ics_download_web.dart` / `ics_download_stub.dart` implement platform-conditional logic. The `_web.dart` variant runs on web; `_stub.dart` is the fallback.
- **Sessions**: Stored in PostgreSQL for serverless cold-start recovery (`AppSessionModel`). Live client objects are rebuilt on demand, not serialized.
- **Rate limiting**: `slowapi` middleware on the API. Respect `X-Forwarded-For` from Workers.
- **CORS**: Configured per-origin. Regex pattern allows `localhost`, `192.168.*`, and `*.pages.dev`/`*.vercel.app`.
- **No `.env` in repo**: `.env` is gitignored. Use `.env.example` as template.
- **Screenshots/`.png` in root**: Debug artifacts, gitignored. Don't commit new ones.

## Key files for common tasks

| Task | File(s) |
|---|---|
| Add a new API endpoint | `services/api/app/routes/` (add route), `routes/deps.py` (auth), `main.py` (register router) |
| Modify login flow | `apps/mobile_web/web/_worker.js` (edge), `services/api/app/routes/auth.py` (backend), `services/api/app/cas_auto_login.py` |
| Change DB schema | `services/api/app/database.py` (add model + `_ensure_columns` migration) |
| Flutter UI theme | `apps/mobile_web/lib/gzus_design.dart` |
| Push notifications | `services/api/app/push.py`, `services/api/app/jobs.py`, `apps/mobile_web/lib/push_service.dart` |
| Cloudflare Worker | `apps/mobile_web/web/_worker.js` (edit), `wrangler.toml` (config) |

### Backend key files (`services/api/app/`)

| File | Purpose |
|---|---|
| `main.py` | App entry — creates FastAPI, registers middleware, routes, lifespan |
| `config.py` | Pydantic Settings, all env vars |
| `database.py` | SQLAlchemy models and engine management |
| `routes/deps.py` | Dependency injection (Worker session recovery, auth) |
| `school_client.py` | School portal client (JWXT 教务系统) — largest file, ~85KB |
| `ehall_client.py` | ehall (一站式服务) client |
| `ecard_client.py` | 一卡通 client |
| `jobs.py` | Background pollers (notifications, exam reminders, grade updates, utility reminders) |
| `push.py` | Web push notifications |

### Flutter frontend key files (`apps/mobile_web/lib/`)

| File | Purpose |
|---|---|
| `main.dart` | Main app — ~530KB, contains all page UI |
| `api_client.dart` | API client — ~84KB, all API calls |
| `gzus_design.dart` | Design theme / UI components |
| `services_deferred.dart` | Deferred loading service module config |
