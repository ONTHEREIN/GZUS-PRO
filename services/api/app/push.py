from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

import httpx
from pywebpush import webpush, WebPushException

from app.config import get_settings
from app.database import WebPushSubscription, get_sync_session_factory

logger = logging.getLogger(__name__)

JPUSH_API_URL = "https://api.jpush.cn/v3/push"


def _build_notification(title: str, alert: str, extras: dict | None = None) -> dict:
    return {
        "alert": alert,
        "android": {
            "alert": alert,
            "extras": extras or {},
        },
        "ios": {
            "alert": alert,
            "title": title,
            "extras": extras or {},
        },
    }


def is_web_push_enabled() -> bool:
    settings = get_settings()
    return bool(settings.web_push_vapid_public_key and settings.web_push_vapid_private_key)


def send_web_push_to_student(student_id: str, title: str, body: str, extras: dict | None = None) -> None:
    """
    Send a web push notification to all subscriptions for a student.
    """
    if not is_web_push_enabled():
        return

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


async def send_push(
    registration_ids: list[str],
    title: str,
    alert: str,
    extras: dict | None = None,
) -> bool:
    settings = get_settings()
    if not settings.jpush_app_key or not settings.jpush_master_secret:
        logger.warning("JPush credentials not configured, skipping push")
        return False
    if not registration_ids:
        return False
    payload = {
        "platform": "all",
        "audience": {"registration_id": registration_ids},
        "notification": _build_notification(title, alert, extras),
        "options": {
            "apns_production": not settings.debug,
        },
    }
    auth = (settings.jpush_app_key, settings.jpush_master_secret)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(JPUSH_API_URL, json=payload, auth=auth)
            response.raise_for_status()
            logger.info("JPush sent to %d devices: %s", len(registration_ids), title)
            return True
    except httpx.HTTPError as exc:
        logger.error("JPush API call failed: %s", exc)
        return False
    except Exception as exc:
        logger.error("JPush unexpected error: %s", exc)
        return False


async def send_broadcast(
    title: str,
    alert: str,
    extras: dict | None = None,
) -> bool:
    settings = get_settings()
    if not settings.jpush_app_key or not settings.jpush_master_secret:
        logger.warning("JPush credentials not configured, skipping push")
        return False
    payload = {
        "platform": "all",
        "audience": "all",
        "notification": _build_notification(title, alert, extras),
        "options": {
            "apns_production": not settings.debug,
        },
    }
    auth = (settings.jpush_app_key, settings.jpush_master_secret)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(JPUSH_API_URL, json=payload, auth=auth)
            response.raise_for_status()
            logger.info("JPush broadcast sent: %s", title)
            return True
    except httpx.HTTPError as exc:
        logger.error("JPush broadcast failed: %s", exc)
        return False
    except Exception as exc:
        logger.error("JPush unexpected error: %s", exc)
        return False


async def send_push_to_all(
    registration_ids: list[str],
    title: str,
    alert: str,
    extras: dict | None = None,
) -> bool:
    if len(registration_ids) <= 1000:
        return await send_push(registration_ids, title, alert, extras)
    all_ok = True
    for i in range(0, len(registration_ids), 1000):
        batch = registration_ids[i : i + 1000]
        ok = await send_push(batch, title, alert, extras)
        if not ok:
            all_ok = False
    return all_ok
