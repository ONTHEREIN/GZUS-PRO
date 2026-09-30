"""发布前置检查的最小集成测试。"""

import pytest

from app.config import get_settings
from app.deployment_preflight import (
    DeploymentPreflightError,
    run_preflight,
    validate_production_settings,
)
from app.main import create_app


def test_preflight_checks_registered_mini_program_routes_and_database(monkeypatch) -> None:
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_ID", "wx-ci-test")
    monkeypatch.setenv("WECHAT_MINIPROGRAM_APP_SECRET", "ci-test-secret")
    get_settings.cache_clear()

    run_preflight(create_app(), get_settings(), production=False, check_database=True)


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
    get_settings.cache_clear()

    with pytest.raises(DeploymentPreflightError, match="WECHAT_MINIPROGRAM_APP_ID"):
        validate_production_settings(get_settings())
