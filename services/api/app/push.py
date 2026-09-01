from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

from cryptography.hazmat.primitives import serialization

from app.config import get_settings
from app.database import WebPushSubscription, get_sync_session_factory
from app.apns_service import send_apns_to_student

logger = logging.getLogger(__name__)


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
    """
    Send a web push notification to all subscriptions for a student.
    """
    if not is_web_push_enabled():
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
            return 0

        for sub in subscriptions:
            try:
                subscription_info = {
                    "endpoint": sub.endpoint,
                    "keys": {
                        "p256dh": sub.p256dh,
                        "auth": sub.auth
                    }
                }
                
                payload = json.dumps({
                    "title": title,
                    "body": body,
                    "extras": extras or {}
                })
                
                webpush(
                    subscription_info=subscription_info,
                    data=payload,
                    vapid_private_key=settings.web_push_vapid_private_key,
                    vapid_claims={
                        "sub": settings.web_push_vapid_subject,
                        "exp": int((datetime.now(timezone.utc).timestamp() + 86400))
                    }
                )
                
                delivered += 1
                logger.info("web_push_sent", extra={"student_id": student_id})
                
            except WebPushException as e:
                if e.response and e.response.status_code in (404, 410):
                    # Subscription is invalid, delete it
                    logger.warning("web_push_subscription_removed", extra={"student_id": student_id})
                    db.delete(sub)
                    db.commit()
                else:
                    logger.error("web_push_delivery_failed", extra={"student_id": student_id}, exc_info=True)
            except Exception:
                logger.error("web_push_delivery_unexpected", extra={"student_id": student_id}, exc_info=True)
    return delivered


def send_push_to_student(student_id: str, title: str, body: str, extras: dict | None = None) -> int:
    """向同一学生的 Web Push 与 iOS APNs 设备投递通知。"""
    delivered = send_web_push_to_student(student_id, title, body, extras)
    send_apns_to_student(student_id, title, body, extras)
    return delivered
