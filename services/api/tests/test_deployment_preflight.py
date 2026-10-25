"""发布前置检查的最小集成测试。"""

import pytest
from fastapi import FastAPI

from app.config import get_settings
from app.deployment_preflight import (
    DeploymentPreflightError,
    run_preflight,
    validate_production_settings,
    validate_registered_routes,
)
from app.main import create_app
from app.routes import mini_program


def test_preflight_checks_registered_mini_program_routes_and_database(monkeypatch) -> None:
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-ci-test")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "ci-test-secret")
    get_settings.cache_clear()

    run_preflight(create_app(), get_settings(), production=False, check_database=True)


def test_preflight_rejects_missing_notification_routes() -> None:
    application = FastAPI()
    application.include_router(mini_program.router)

    with pytest.raises(DeploymentPreflightError, match="/mini/notifications/config"):
        validate_registered_routes(application)


def test_production_preflight_rejects_demo_account_with_actionable_message(monkeypatch) -> None:
    monkeypatch.setenv("DEBUG", "false")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "true")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-ci-test")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "ci-test-secret")
    get_settings.cache_clear()

    with pytest.raises(RuntimeError, match="生产环境禁止启用 DEMO_ACCOUNT_ENABLED"):
        get_settings()


def test_production_preflight_reports_missing_wechat_configuration(monkeypatch) -> None:
    monkeypatch.setenv("DEBUG", "false")
    monkeypatch.setenv("DEMO_ACCOUNT_ENABLED", "false")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "")
    monkeypatch.setenv("RSA_PRIVATE_KEY", "preflight-config-test")
    get_settings.cache_clear()

    with pytest.raises(DeploymentPreflightError, match="WECHAT_MINIPROGRAM_APP_ID"):
        validate_production_settings(get_settings())
