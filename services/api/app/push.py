from __future__ import annotations

import base64
import binascii
import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlparse

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import get_settings
from app.database import WebPushSubscription, get_sync_session_factory
from app.apns_service import send_apns_to_student, send_live_activity_to_student

logger = logging.getLogger(__name__)
_WEB_PUSH_HOSTS = {
    "fcm.googleapis.com",
    "updates.push.services.mozilla.com",
    "web.push.apple.com",
}


def validate_web_push_endpoint(endpoint: str) -> str:
    """只接受浏览器推送服务地址，避免服务端向客户端指定的内网地址发请求。"""
    parsed = urlparse(endpoint)
    host = parsed.hostname
    if (
        parsed.scheme != "https"
        or host is None
        or (host not in _WEB_PUSH_HOSTS and not host.endswith(".notify.windows.com"))
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("Web Push endpoint 必须是浏览器推送服务的 HTTPS 地址")
    return endpoint


def validate_web_push_keys(p256dh: str, auth: str) -> None:
    """验证浏览器 PushSubscription 密钥，避免无效订阅进入投递队列。"""
    try:
        public_key = base64.b64decode(
            p256dh + "=" * (-len(p256dh) % 4), altchars=b"-_", validate=True
        )
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public_key)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Web Push p256dh 公钥无效") from exc
    try:
        auth_secret = base64.b64decode(
            auth + "=" * (-len(auth) % 4), altchars=b"-_", validate=True
        )
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Web Push auth 密钥无效") from exc
    if len(auth_secret) != 16:
        raise ValueError("Web Push auth 密钥必须为 16 字节")


@dataclass(frozen=True)
class PushDeliveryResult:
    """记录普通通知和灵动岛的独立投递结果。"""

    regular_delivered: int = 0
    live_activity_delivered: int = 0

    @property
    def total_channels(self) -> int:
        return self.regular_delivered + self.live_activity_delivered

    def __eq__(self, other: object) -> bool:
        if isinstance(other, int):
            return self.total_channels == other
        if not isinstance(other, PushDeliveryResult):
            return NotImplemented
        return (
            self.regular_delivered == other.regular_delivered
            and self.live_activity_delivered == other.live_activity_delivered
        )


def web_push_public_key() -> str | None:
    """从 py-vapid 使用的私钥派生浏览器要求的 Base64URL 公钥。"""
    private_key = get_settings().web_push_vapid_private_key.strip()
    if not private_key:
        return None
    try:
        from py_vapid import Vapid

        vapid = Vapid.from_string(private_key)
        raw = vapid.public_key.public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
    except Exception:
        logger.exception("web_push_vapid_key_invalid")
        return None
    import base64

    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def is_web_push_enabled() -> bool:
    return web_push_public_key() is not None


def send_web_push_to_student(student_id: str, title: str, body: str, extras: dict | None = None) -> int:
    """向学生的浏览器推送订阅投递通知。"""
    if not is_web_push_enabled():
        logger.error(
            "web_push_configuration_unavailable",
            extra={"student_id": student_id},
        )
        return 0

    from pywebpush import WebPushException, webpush

    settings = get_settings()
    factory = get_sync_session_factory()
    delivered = 0
    with factory() as db:
        subscriptions = db.query(WebPushSubscription).filter(
            WebPushSubscription.student_id == student_id
        ).all()
        if not subscriptions:
            logger.warning(
                "web_push_no_subscriptions",
                extra={"student_id": student_id},
            )
            return 0

        with requests.Session() as push_http:
            push_http.max_redirects = 0
            for sub in subscriptions:
                try:
                    validate_web_push_endpoint(sub.endpoint)
                except ValueError:
                    logger.warning(
                        "web_push_untrusted_endpoint_removed",
                        extra={"student_id": student_id, "subscription_id": sub.id},
                    )
                    db.delete(sub)
                    db.commit()
                    continue
                try:
                    subscription_info = {
                        "endpoint": sub.endpoint,
                        "keys": {"p256dh": sub.p256dh, "auth": sub.auth},
                    }
                    payload = json.dumps({
                        "title": title,
                        "body": body,
                        "extras": extras or {},
                    })
                    webpush(
                        subscription_info=subscription_info,
                        data=payload,
                        vapid_private_key=settings.web_push_vapid_private_key,
                        vapid_claims={
                            "sub": settings.web_push_vapid_subject,
                            "exp": int(datetime.now(timezone.utc).timestamp() + 86400),
                        },
                        requests_session=push_http,
                        timeout=10,
                    )
                    delivered += 1
                    logger.info("web_push_sent", extra={"student_id": student_id})
                except WebPushException as e:
                    if e.response and e.response.status_code in (404, 410):
                        logger.warning("web_push_subscription_removed", extra={"student_id": student_id})
                        db.delete(sub)
                        db.commit()
                    else:
                        logger.error(
                            "web_push_delivery_failed",
                            extra={"student_id": student_id},
                            exc_info=True,
                        )
                except Exception:
                    logger.error(
                        "web_push_delivery_unexpected",
                        extra={"student_id": student_id},
                        exc_info=True,
                    )
    return delivered


def send_push_to_student(
    student_id: str, title: str, body: str, extras: dict | None = None
) -> PushDeliveryResult:
    """向同一学生的 Web Push 与 iOS APNs 设备投递通知。"""
    regular_delivered = 0
    try:
        regular_delivered += send_web_push_to_student(student_id, title, body, extras)
    except Exception:
        logger.exception("web_push_channel_unexpected", extra={"student_id": student_id})
    apns_delivered = 0
    try:
        # Live Activity 是附加展示，不能替代普通通知。
        apns_delivered = send_apns_to_student(student_id, title, body, extras)
    except Exception:
        logger.exception("apns_channel_unexpected", extra={"student_id": student_id})

    live_delivered = 0
    if extras and extras.get("liveUpdate") is True:
        live_event = extras.get("liveEvent") or "start"
        if live_event not in {"start", "update", "end"}:
            logger.error(
                "live_activity_event_invalid",
                extra={"student_id": student_id, "live_event": str(live_event)},
            )
        else:
            try:
                live_delivered = send_live_activity_to_student(
                    student_id,
                    live_event,
                    title,
                    body,
                    extras,
                )
            except Exception:
                logger.exception("live_activity_channel_unexpected", extra={"student_id": student_id})
    return PushDeliveryResult(
        regular_delivered=regular_delivered + apns_delivered,
        live_activity_delivered=live_delivered,
    )
