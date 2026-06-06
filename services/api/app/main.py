import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.database import init_db
from app.jobs import NoticeCache, run_ecard_reminder_poller, run_notice_poller
from app.routes import academic, auth, ecard, ehall, push, version
from app.sessions import SessionStore
from app.ws import ConnectionManager, ws_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    poller_task = asyncio.create_task(run_notice_poller(app))
    ecard_task = asyncio.create_task(run_ecard_reminder_poller(app))
    await app.state.sessions.start_cleanup_task()
    yield
    poller_task.cancel()
    ecard_task.cancel()
    app.state.sessions.stop_cleanup_task()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="GZUS-PRO API", version="0.1.0", lifespan=lifespan)
    app.state.sessions = SessionStore(settings.session_ttl_seconds)
    app.state.pending_captcha = {}
    app.state.ly_sso_states = {}
    app.state.ly_sso_proxy_granting_tickets = {}
    app.state.ly_sso_results = {}
    app.state.ws_manager = ConnectionManager()
    app.state.notice_cache = NoticeCache()

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_origin_regex=settings.cors_origin_regex,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(auth.router)
    app.include_router(academic.router)
    app.include_router(ehall.router)
    app.include_router(ecard.router)
    app.include_router(push.router)
    app.include_router(version.router)
    app.include_router(ws_router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
