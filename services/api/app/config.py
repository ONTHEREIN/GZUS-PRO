from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    jw_base_url: str = "https://jwxt.seig.edu.cn/jwglxt"
    ehall_base_url: str = "https://ehall.gzus.edu.cn"
    cas_login_url: str = "https://cas.gzus.edu.cn/lyuapServer/login"
    ehall_service_url: str = "http://ehall.gzus.edu.cn/shiro-cas"
    jwxt_sso_service_url: str = "https://jwxt.seig.edu.cn/sso/lyiotlogin"
    public_api_base_url: str = "http://127.0.0.1:8000"
    frontend_base_url: str = "http://localhost:8080"
    cors_origins: str = Field(
        default="http://localhost:3000,http://localhost:5173,http://localhost:8080,http://127.0.0.1:8080"
    )
    cors_origin_regex: str = r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"
    session_ttl_seconds: int = 7200
    sso_ttl_seconds: int = 300
    request_timeout_seconds: int = 15

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
