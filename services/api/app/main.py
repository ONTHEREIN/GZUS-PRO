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
from app.database import get_sync_session_factory, init_db
from app.jobs import ExamReminderCache, GradeUpdateCache, NoticeCache, run_ecard_reminder_poller, run_exam_reminder_poller, run_grade_update_poller, run_notice_poller
from app.rate_limit import limiter
from app.routes import academic, auth, ecard, ehall, push, weather
from app.rsa_keys import rsa_key_manager
from app.sessions import SessionStore
from app.ws import ConnectionManager, ws_router

IS_VERCEL = os.environ.get("VERCEL") == "1"
MAX_BODY_BYTES = 10 * 1024 * 1024


def _security_headers(settings) -> dict[str, str]:
    headers = {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    }
    if not settings.debug:
        headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return headers


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
    app.state.sessions = SessionStore(settings.session_ttl_seconds, db_factory=get_sync_session_factory)
    app.state.pending_captcha = {}
    app.state.ly_sso_states = {}
    app.state.ws_manager = ConnectionManager()
    app.state.notice_cache = NoticeCache()
    app.state.exam_reminder_cache = ExamReminderCache()
    app.state.grade_update_cache = GradeUpdateCache()
    app.state.rsa_key_manager = rsa_key_manager

    security_headers = _security_headers(settings)

    @app.middleware("http")
    async def security_and_body_limits(request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                size = int(content_length)
            except ValueError:
                response = JSONResponse(
                    status_code=400,
                    content={"detail": "Content-Length 无效"},
                )
            else:
                if size > MAX_BODY_BYTES:
                    response = JSONResponse(
                        status_code=413,
                        content={"detail": "请求体过大，最大支持 10MB"},
                    )
                else:
                    response = await call_next(request)
        else:
            response = await call_next(request)
        for key, value in security_headers.items():
            response.headers.setdefault(key, value)
        return response

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
    app.include_router(weather.router)
    app.include_router(ws_router)

    # Internal endpoints for Cloudflare Worker
    from app.routes.internal import router as internal_router
    app.include_router(internal_router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
