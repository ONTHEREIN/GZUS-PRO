import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware

from app.cache_service import ExamReminderCache, GradeUpdateCache, NoticeCache
from app.config import get_settings
from app.database import check_database_ready, get_sync_session_factory, init_db
from app.rate_limit import limiter
from app.routes import academic, admin, auth, content, ecard, ehall, push, settings, weather
from app.rsa_keys import rsa_key_manager
from app.sessions import SessionStore, SessionStoreUnavailableError
from app.ws import ConnectionManager, ws_router

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
    from app.jobs import (
        run_ecard_reminder_poller,
        run_exam_reminder_poller,
        run_grade_update_poller,
        run_notice_poller,
    )

    init_db()
    poller_task = asyncio.create_task(run_notice_poller(app))
    ecard_task = asyncio.create_task(run_ecard_reminder_poller(app))
    exam_task = asyncio.create_task(run_exam_reminder_poller(app))
    grade_task = asyncio.create_task(run_grade_update_poller(app))
    await app.state.sessions.start_cleanup_task()
    yield
    poller_task.cancel()
    ecard_task.cancel()
    exam_task.cancel()
    grade_task.cancel()
    app.state.sessions.stop_cleanup_task()


def create_app() -> FastAPI:
    # 注意：局部变量用 cfg 而非 settings，避免遮蔽 app.routes.settings 模块
    cfg = get_settings()
    app = FastAPI(title="软帮手 API", version="0.1.1", lifespan=lifespan)
    app.state.sessions = SessionStore(cfg.session_ttl_seconds, db_factory=get_sync_session_factory)
    app.state.ly_sso_states = {}
    app.state.ly_sso_handoffs = {}
    app.state.ws_manager = ConnectionManager()
    app.state.notice_cache = NoticeCache()
    app.state.exam_reminder_cache = ExamReminderCache()
    app.state.grade_update_cache = GradeUpdateCache()
    app.state.rsa_key_manager = rsa_key_manager

    security_headers = _security_headers(cfg)

    @app.middleware("http")
    async def security_and_body_limits(request: Request, call_next):
        trace_id = request.headers.get("X-GZUS-Trace-Id", "").strip()
        if not trace_id or len(trace_id) > 128:
            trace_id = uuid.uuid4().hex
        request.state.trace_id = trace_id
        started_at = time.perf_counter()
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
        response.headers.setdefault("X-GZUS-Trace-Id", trace_id)
        logging.getLogger("app.request").info(
            "request_completed",
            extra={
                "trace_id": trace_id,
                "method": request.method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": round((time.perf_counter() - started_at) * 1000, 2),
            },
        )
        return response

    # Rate limiting
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.add_middleware(SlowAPIMiddleware)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=cfg.cors_origin_list,
        allow_origin_regex=cfg.cors_origin_regex_value,
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=[
            "X-Session-Id",
            "X-Client-Platform",
            "X-GZUS-Trace-Id",
            "Content-Type",
            "User-Agent",
        ],
    )

    @app.exception_handler(Exception)
    async def global_exception_handler(request: Request, exc: Exception):
        """Catch all unhandled exceptions, log them, and return a 500."""
        logger = logging.getLogger("app.main")
        logger.error(
            "unhandled_exception",
            extra={
                "trace_id": getattr(request.state, "trace_id", None),
                "method": request.method,
                "path": request.url.path,
                "error_type": type(exc).__name__,
            },
            exc_info=True,
        )
        return JSONResponse(
            status_code=500,
            content={"detail": "服务器内部错误，请稍后重试"},
        )

    @app.exception_handler(SessionStoreUnavailableError)
    async def session_store_exception_handler(
        request: Request,
        exc: SessionStoreUnavailableError,
    ) -> JSONResponse:
        logger = logging.getLogger("app.main")
        logger.error(
            "Session storage unavailable",
            extra={
                "method": request.method,
                "path": request.url.path,
                "error_type": type(exc).__name__,
            },
            exc_info=True,
        )
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"detail": "会话服务暂时不可用，请稍后重试"},
        )

    app.include_router(auth.router)
    app.include_router(content.router)
    app.include_router(academic.router)
    app.include_router(admin.router)
    app.include_router(ehall.router)
    app.include_router(ecard.router)
    app.include_router(push.router)
    app.include_router(weather.router)
    app.include_router(settings.router)
    app.include_router(ws_router)

    # Internal cron endpoints are only reachable from the loopback server.
    from app.routes.internal import router as internal_router
    app.include_router(internal_router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/health/ready")
    def ready() -> dict[str, str]:
        try:
            check_database_ready()
        except Exception as exc:
            logging.getLogger("app.main").error(
                "readiness_check_failed",
                extra={"error_type": type(exc).__name__},
                exc_info=True,
            )
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={"status": "unavailable"},
            )
        return {"status": "ready"}

    return app


app = create_app()
