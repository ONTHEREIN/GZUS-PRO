"""API 发布前置检查。

这些检查同时供 CI 和生产 release 激活脚本使用，避免「测试通过但候选版本
缺路由/缺生产配置/迁移未完成」直到服务切换后才暴露。
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from fastapi import FastAPI
from sqlalchemy.exc import SQLAlchemyError

from app.config import Settings, get_settings
from app.database import check_database_ready, init_db

MINI_PROGRAM_ROUTE_PATHS: tuple[str, ...] = (
    "/mini/auth/login",
    "/mini/auth/wechat-login",
    "/mini/auth/wechat-binding",
)


class DeploymentPreflightError(RuntimeError):
    """发布前置检查失败。"""


def validate_registered_routes(application: FastAPI) -> None:
    """确认小程序核心路由已经挂载到 FastAPI 应用。"""
    registered_paths = set(application.openapi().get("paths", {}))
    missing_paths = [path for path in MINI_PROGRAM_ROUTE_PATHS if path not in registered_paths]
    if missing_paths:
        missing = ", ".join(missing_paths)
        raise DeploymentPreflightError(
            f"发布前置检查失败：mini_program 路由未注册，缺少 {missing}；"
            "请确认 app.main.include_router(mini_program.router) 未被删除。"
        )


def validate_production_settings(settings: Settings) -> None:
    """确认生产环境不会启用演示账号且微信小程序配置完整。"""
    failures: list[str] = []
    if settings.debug:
        failures.append("DEBUG 必须为 false")
    if settings.demo_account_enabled:
        failures.append("DEMO_ACCOUNT_ENABLED 必须为 false")
    if not settings.database_url.startswith(
        ("postgres://", "postgresql://", "postgresql+asyncpg://")
    ):
        failures.append("DATABASE_URL 必须使用 PostgreSQL")

    required_wechat_settings = {
        "WECHAT_MINIPROGRAM_APP_ID": settings.wechat_miniprogram_app_id,
        "WECHAT_MINIPROGRAM_APP_SECRET": settings.wechat_miniprogram_app_secret,
    }
    missing_wechat_settings = [
        name for name, value in required_wechat_settings.items() if not value.strip()
    ]
    if missing_wechat_settings:
        failures.append("缺少微信小程序配置：" + ", ".join(missing_wechat_settings))

    if failures:
        raise DeploymentPreflightError("生产发布前置检查失败：" + "；".join(failures))


def validate_database_migrations() -> None:
    """执行幂等迁移后检查数据库连接和当前模型 schema 是否就绪。"""
    try:
        init_db()
        check_database_ready()
    except (RuntimeError, SQLAlchemyError) as exc:
        raise DeploymentPreflightError(
            "数据库迁移就绪检查失败：迁移未完成或数据库不可用；"
            f"{type(exc).__name__}: {exc}"
        ) from exc


def run_preflight(
    application: FastAPI,
    settings: Settings,
    production: bool,
    check_database: bool,
) -> None:
    """运行指定范围的发布前置检查。"""
    validate_registered_routes(application)
    if production:
        validate_production_settings(settings)
    if check_database:
        validate_database_migrations()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OneGZUS API 发布前置检查")
    parser.add_argument(
        "--production",
        action="store_true",
        help="检查生产安全配置（DEBUG、演示账号、微信小程序密钥）",
    )
    parser.add_argument(
        "--check-database",
        action="store_true",
        help="执行幂等迁移并检查数据库 schema 就绪状态",
    )
    return parser


def main(arguments: Sequence[str]) -> int:
    """命令行入口。"""
    options = _parser().parse_args(arguments)
    try:
        from app.main import app

        run_preflight(app, get_settings(), options.production, options.check_database)
    except DeploymentPreflightError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except RuntimeError as exc:
        print(f"发布前置检查失败：{exc}", file=sys.stderr)
        return 1
    print("API 发布前置检查通过：路由、生产配置和数据库状态均符合要求。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
