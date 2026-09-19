"""微信小程序身份交换与绑定辅助。"""

from __future__ import annotations

import hashlib
import hmac
import logging
import time
from dataclasses import dataclass

import httpx

from app.config import get_settings
from app.sessions import _get_fernet

logger = logging.getLogger(__name__)

_CODE2SESSION_URL = "https://api.weixin.qq.com/sns/jscode2session"
_EXCHANGE_ATTEMPTS = 3
_RETRY_DELAY_SECONDS = 0.3


class WechatIdentityError(RuntimeError):
    """微信身份 code 无法兑换。"""


class WechatNotConfiguredError(WechatIdentityError):
    """微信小程序登录尚未配置。"""


@dataclass(frozen=True)
class WechatIdentity:
    app_id: str
    openid: str


def exchange_code(code: str) -> WechatIdentity:
    """用一次性 wx.login code 换取当前小程序 OpenID。"""
    settings = get_settings()
    app_id = settings.wechat_miniprogram_app_id.strip()
    app_secret = settings.wechat_miniprogram_app_secret.strip()
    if not app_id or not app_secret:
        raise WechatNotConfiguredError("微信小程序登录尚未配置")

    last_error: Exception | None = None
    for attempt in range(1, _EXCHANGE_ATTEMPTS + 1):
        try:
            with httpx.Client(timeout=settings.request_timeout_seconds) as client:
                response = client.get(
                    _CODE2SESSION_URL,
                    params={
                        "appid": app_id,
                        "secret": app_secret,
                        "js_code": code,
                        "grant_type": "authorization_code",
                    },
                )
                response.raise_for_status()
                payload = response.json()
            if not isinstance(payload, dict):
                raise WechatIdentityError("微信身份响应格式无效")
            error_code = payload.get("errcode")
            if error_code not in (None, 0):
                raise WechatIdentityError("微信登录凭证无效或已使用")
            openid = payload.get("openid")
            if not isinstance(openid, str) or not openid:
                raise WechatIdentityError("微信身份响应缺少 OpenID")
            return WechatIdentity(app_id=app_id, openid=openid)
        except WechatIdentityError:
            raise
        except (httpx.HTTPError, ValueError, TypeError) as exc:
            last_error = exc
            logger.warning(
                "wechat_code_exchange_failed",
                extra={"attempt": attempt, "max_attempts": _EXCHANGE_ATTEMPTS},
                exc_info=attempt == _EXCHANGE_ATTEMPTS,
            )
            if attempt < _EXCHANGE_ATTEMPTS:
                time.sleep(_RETRY_DELAY_SECONDS * attempt)
    raise WechatIdentityError("微信登录服务暂时不可用，请稍后重试") from last_error


def openid_fingerprint(identity: WechatIdentity) -> str:
    """生成按 AppID 隔离的不可逆 OpenID 查询指纹。"""
    key = get_settings().credential_encryption_key
    if not key:
        raise RuntimeError("CREDENTIAL_ENCRYPTION_KEY 未配置，无法保存微信绑定")
    value = f"{identity.app_id}\x00{identity.openid}".encode("utf-8")
    return hmac.new(key.encode("utf-8"), value, hashlib.sha256).hexdigest()


def encrypt_openid(openid: str) -> str:
    key = get_settings().credential_encryption_key
    if not key:
        raise RuntimeError("CREDENTIAL_ENCRYPTION_KEY 未配置，无法保存微信绑定")
    return _get_fernet(key).encrypt(openid.encode("utf-8")).decode("ascii")
