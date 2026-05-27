from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.routes import academic, auth
from app.sessions import SessionStore


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="GZUS-PRO API", version="0.1.0")
    app.state.sessions = SessionStore(settings.session_ttl_seconds)
    app.state.pending_captcha = {}
    app.state.ly_sso_states = {}
    app.state.ly_sso_proxy_granting_tickets = {}
    app.state.ly_sso_results = {}

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_origin_regex=settings.cors_origin_regex,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(auth.router)
    app.include_router(academic.router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
