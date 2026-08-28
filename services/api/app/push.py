from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

from app.config import get_settings
from app.database import WebPushSubscription, get_sync_session_factory
from app.apns_service import send_apns_to_student

logger = logging.getLogger(__name__)

def is_web_push_enabled() -> bool:
    settings = get_settings()
    return bool(settings.web_push_vapid_public_key and settings.web_push_vapid_private_key)


def send_web_push_to_student(student_id: str, title: str, body: str, extras: dict | None = None) -> None:
    """
    Send a web push notification to all subscriptions for a student.
    """
    if not is_web_push_enabled():
        return

    from pywebpush import WebPushException, webpush

    settings = get_settings()
    factory = get_sync_session_factory()
    
    with factory() as db:
        subscriptions = db.query(WebPushSubscription).filter(
            WebPushSubscription.student_id == student_id
        ).all()
        
        if not subscriptions:
            return

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
                
                logger.info(f"Web push sent to {sub.endpoint[:30]}...")
                
            except WebPushException as e:
                if e.response and e.response.status_code in (404, 410):
                    # Subscription is invalid, delete it
                    logger.warning(f"Removing invalid subscription {sub.endpoint[:30]}...")
                    db.delete(sub)
                    db.commit()
                else:
                    logger.error(f"Web push failed for {sub.endpoint[:30]}: {e}")
            except Exception as e:
                logger.error(f"Unexpected error sending web push: {e}")


def send_push_to_student(student_id: str, title: str, body: str, extras: dict | None = None) -> None:
    """向同一学生的 Web Push 与 iOS APNs 设备投递通知。"""
    send_web_push_to_student(student_id, title, body, extras)
    send_apns_to_student(student_id, title, body, extras)
