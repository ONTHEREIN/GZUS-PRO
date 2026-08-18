from functools import lru_cache
from pathlib import Path
from urllib.parse import urlparse

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

ENV_FILE = Path(__file__).resolve().parents[1] / ".env"


class Settings(BaseSettings):
    jw_base_url: str = "https://jwxt.gzus.edu.cn/jwglxt"
    jwxt_worker_proxy_origin: str = ""  # e.g. https://onegzus-onweb.pages.dev - route JWXT through Worker
    ehall_base_url: str = "https://ehall.gzus.edu.cn"
    ehall_staff_sync_url: str = ""
    ehall_staff_json_path: str = ""
    cas_login_url: str = "https://cas.gzus.edu.cn/lyuapServer/login"
    ehall_service_url: str = "http://ehall.gzus.edu.cn/shiro-cas"
    jwxt_sso_service_url: str = "https://jwxt.gzus.edu.cn/sso/lyiotlogin"
    public_api_base_url: str = "http://127.0.0.1:8000"
    frontend_base_url: str = "http://localhost:8080"
    cors_origins: str = Field(
        default="http://localhost:3000,http://localhost:5173,http://localhost:8080,http://127.0.0.1:8080,http://192.168.6.230:8080"
    )
    cors_origin_regex: str = r"^https?://(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3})(:\d+)?$"
    session_ttl_seconds: int = 7200
    sso_ttl_seconds: int = 300
    request_timeout_seconds: int = 6
    request_connect_timeout_seconds: int = 5
    cas_login_timeout_seconds: int = 60
    jpush_app_key: str = ""
    jpush_master_secret: str = ""
    push_poll_interval_seconds: int = 1800
    ws_heartbeat_seconds: int = 30
    debug: bool = False
    database_url: str = ""
    db_pool_size: int = 3
    db_max_overflow: int = 5
    db_pool_timeout: int = 10
    db_pool_recycle: int = 300
    ehall_session_ttl_hours: int = 24
    ecard_base_url: str = "https://ecarduser.gzus.edu.cn"
    ecard_worker_proxy_origin: str = ""
    ecard_openid: str = ""
    ecard_unionid: str = ""
    ecard_secret: str = ""
    ecard_verify_tls: bool = False
    ecard_daily_reminder_hour: int = 8
    ecard_daily_reminder_minute: int = 0
    ehall_csrf_key: str = ""
    credential_encryption_key: str = ""
    rsa_private_key_pem: str = ""
    internal_api_key: str = ""  # Key for Cloudflare Worker to call internal endpoints
    web_push_vapid_public_key: str = ""
    web_push_vapid_private_key: str = ""
    web_push_vapid_subject: str = "mailto:example@example.com"
    app_latest_version: str = "0.1.1-Dev"
    app_latest_build: str = "4"
    app_min_supported_version: str = "0.0.1"
    app_min_supported_build: str = "1"
    app_download_url: str = ""
    app_release_notes: str = "Dev"
    # 管理后台首个 owner 学号（逗号分隔，可多个）；启动时幂等写入 admin_users 表
    admin_seed_owner: str = ""
    # 微信公众号「合集」链接（含 __biz 与 album_id）；空=该通道关闭。
    # 通过公开合集接口匿名拉取文章列表（标题/封面/链接/发布时间），无需 AppID/Secret。
    wechat_album_url: str = ""
    # wechatrss（第三方 RSS 服务）订阅源完整 URL（含 token）。
    # 配置后优先于合集通道；token 为私人密钥，禁止写入日志/响应（见 routes/admin.py 脱敏）。
    wechat_rss_url: str = ""
    # 公众号文章自动同步间隔（小时）；cron 定时 + 读通知时的惰性兜底都遵循此间隔
    wechat_sync_interval_hours: int = 6

    model_config = SettingsConfigDict(env_file=ENV_FILE, env_file_encoding="utf-8")

    @property
    def cors_origin_list(self) -> list[str]:
        origins = [
            origin.strip().rstrip("/")
            for origin in self.cors_origins.split(",")
            if origin.strip()
        ]
        frontend_origin = self.frontend_origin
        if frontend_origin:
            origins.append(frontend_origin)
        return list(dict.fromkeys(origins))

    @property
    def frontend_origin(self) -> str:
        parsed = urlparse(self.frontend_base_url)
        if not parsed.scheme or not parsed.netloc:
            return ""
        return f"{parsed.scheme}://{parsed.netloc}"

    @property
    def cors_origin_regex_value(self) -> str | None:
        value = self.cors_origin_regex.strip()
        return value or None


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if not settings.debug:
        if not settings.credential_encryption_key:
            raise RuntimeError(
                "CREDENTIAL_ENCRYPTION_KEY must be set to a random key in production. "
                "Generate one with: python -c \"import secrets; print(secrets.token_urlsafe(32))\""
            )
        if settings.public_api_base_url.startswith("http://"):
            raise RuntimeError(
                f"PUBLIC_API_BASE_URL must use HTTPS in production, got: {settings.public_api_base_url}"
            )
        if settings.frontend_base_url.startswith("http://"):
            raise RuntimeError(
                f"FRONTEND_BASE_URL must use HTTPS in production, got: {settings.frontend_base_url}"
            )
    return settings
