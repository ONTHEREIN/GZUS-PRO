import asyncio
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware

from app.config import get_settings
from app.database import init_db
from app.jobs import ExamReminderCache, GradeUpdateCache, NoticeCache, run_ecard_reminder_poller, run_exam_reminder_poller, run_grade_update_poller, run_notice_poller
from app.rate_limit import limiter
from app.routes import academic, auth, ecard, ehall, push
from app.sessions import SessionStore
from app.ws import ConnectionManager, ws_router

IS_VERCEL = os.environ.get("VERCEL") == "1"


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not IS_VERCEL:
        init_db()
        poller_task = asyncio.create_task(run_notice_poller(app))
        ecard_task = asyncio.create_task(run_ecard_reminder_poller(app))
        exam_task = asyncio.create_task(run_exam_reminder_poller(app))
        grade_task = asyncio.create_task(run_grade_update_poller(app))
    await app.state.sessions.start_cleanup_task()
    yield
    if not IS_VERCEL:
        poller_task.cancel()
        ecard_task.cancel()
        exam_task.cancel()
        grade_task.cancel()
    app.state.sessions.stop_cleanup_task()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="OneGZUS API", version="0.1.0", lifespan=lifespan)
    app.state.sessions = SessionStore(settings.session_ttl_seconds)
    app.state.pending_captcha = {}
    app.state.ly_sso_states = {}
    app.state.ly_sso_proxy_granting_tickets = {}
    app.state.ly_sso_results = {}
    app.state.ws_manager = ConnectionManager()
    app.state.notice_cache = NoticeCache()
    app.state.exam_reminder_cache = ExamReminderCache()
    app.state.grade_update_cache = GradeUpdateCache()

    # Request body size limit (10 MB)
    @app.middleware("http")
    async def limit_body_size(request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length and int(content_length) > 10 * 1024 * 1024:
            return JSONResponse(
                status_code=413,
                content={"detail": "请求体过大，最大支持 10MB"},
            )
        return await call_next(request)

    # Rate limiting
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.add_middleware(SlowAPIMiddleware)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_origin_regex=settings.cors_origin_regex_value,
        allow_credentials=False,
        allow_methods=["GET", "POST", "PATCH"],
        allow_headers=["X-Session-Id", "Content-Type", "User-Agent"],
    )

    app.include_router(auth.router)
    app.include_router(academic.router)
    app.include_router(ehall.router)
    app.include_router(ecard.router)
    app.include_router(push.router)
    app.include_router(ws_router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
