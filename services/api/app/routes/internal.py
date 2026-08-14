"""Internal API endpoints for Cloudflare Worker.

These endpoints are called by the Cloudflare Worker running on the edge
to offload operations that require the Python runtime (OCR, SDK, sessions).
They are protected by an internal API key.
"""
from __future__ import annotations

import base64
import json
import logging

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel

from app.captcha_ocr import captcha_ocr
from app.config import get_settings
from app.school_client import SchoolSdkClient

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/internal", tags=["internal"])


def _verify_internal_key(key: str | None) -> None:
    """Verify the internal API key."""
    settings = get_settings()
    expected = settings.internal_api_key
    if not expected:
        raise HTTPException(status_code=503, detail="Internal API key not configured")
    if not key or key != expected:
        raise HTTPException(status_code=403, detail="Invalid internal API key")


class OcrRequest(BaseModel):
    image: str  # base64-encoded image bytes


class DecryptPasswordRequest(BaseModel):
    encrypted_password: str
    key_id: str | None = None  # sent by Worker for key mismatch detection

class CreateSessionRequest(BaseModel):
    account: str
    cookies: str
    ehall_cookies: str | None = None
    ehall_auth_token: str | None = None
    student_name: str | None = None


@router.post("/ocr")
def ocr_endpoint(
    payload: OcrRequest,
    x_internal_key: str | None = Header(None),
) -> dict:
    """OCR endpoint for Cloudflare Worker to call."""
    _verify_internal_key(x_internal_key)
    try:
        image_bytes = base64.b64decode(payload.image)
        text = captcha_ocr.recognize(image_bytes)
        return {"text": text}
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    except Exception as exc:
        logger.warning("OCR failed: %s", exc)
        return {"text": ""}


@router.post("/decrypt-password")
def decrypt_password_endpoint(
    payload: DecryptPasswordRequest,
    x_internal_key: str | None = Header(None),
) -> dict:
    """Decrypt an RSA-encrypted password. Fast endpoint (< 1s)."""
    _verify_internal_key(x_internal_key)
    try:
        from app.rsa_keys import rsa_key_manager
        current_key_id = rsa_key_manager.get_key_id()
        logger.info(
            "decrypt-password: client_keyId=%s, server_keyId=%s, encrypted_password length=%d, key_match=%s",
            payload.key_id,
            current_key_id,
            len(payload.encrypted_password),
            payload.key_id == current_key_id if payload.key_id else "unknown",
        )
        if payload.key_id and payload.key_id != current_key_id:
            logger.warning(
                "decrypt-password: KEY MISMATCH! client_keyId=%s != server_keyId=%s. "
                "This usually means RSA_PRIVATE_KEY is not set on Vercel, causing key rotation on cold start.",
                payload.key_id,
                current_key_id,
            )
            raise HTTPException(
                status_code=400,
                detail=f"RSA密钥不匹配: 前端keyId={payload.key_id}, 后端keyId={current_key_id}. "
                       "请刷新页面获取新公钥后重试。",
            )
        password = rsa_key_manager.decrypt(payload.encrypted_password)
        return {"password": password}
    except HTTPException:
        raise
    except Exception as exc:
        from app.rsa_keys import rsa_key_manager
        logger.error(
            "decrypt-password FAILED: keyId=%s, error=%s: %s",
            rsa_key_manager.get_key_id(),
            type(exc).__name__,
            exc,
            exc_info=True,
        )
        raise HTTPException(status_code=400, detail=f"密码解密失败: {exc}")


@router.post("/create-session")
def create_session_endpoint(
    payload: CreateSessionRequest,
    request: Request,
    x_internal_key: str | None = Header(None),
) -> dict:
    """Create a session from CAS login result (called by Cloudflare Worker).

    Cookies obtained at the Worker edge are IP-bounded to the Worker's IP.
    We skip JWXT validation here (validate=False) so the session is stored
    with the raw cookies.  The Worker will inject fresh cookies on every
    proxied request; the DB-stored cookies serve as a fallback.
    """
    _verify_internal_key(x_internal_key)
    sessions = request.app.state.sessions
    settings = get_settings()

    # Create SchoolSdkClient with the cookies from CAS login.
    # Skip JWXT validation — cookies are IP-bounded to the Worker's edge IP.
    client = SchoolSdkClient(
        base_url=settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
    )
    student_name = payload.student_name
    try:
        # Try validation first, fallback to no-validation on failure
        student_name = client.login_with_cookies(payload.cookies, payload.account, validate=False)
    except Exception as exc:
        logger.warning("login_with_cookies failed in create-session: %s", exc)

    # Create ehall client if ehall cookies are available
    ehall_client = None
    if payload.ehall_cookies:
        try:
            from app.ehall_client import EhallClient
            ehall_client = EhallClient(
                base_url=settings.ehall_base_url,
                cookies=payload.ehall_cookies,
                auth_token=payload.ehall_auth_token,
            )
        except Exception as exc:
            logger.warning("Failed to create ehall client: %s", exc)

    session = None
    try:
        # 管理后台：学号在 admin_users 白名单中则标记 is_admin。
        # 延迟 import 避免与 routes.admin 的模块初始化相互依赖。
        from app.routes.admin import admin_role_of

        role = admin_role_of(payload.account)
        session = sessions.create(
            client,
            student_name=student_name or payload.student_name,
            ehall_client=ehall_client,
            student_account=payload.account,
            is_admin=role is not None,
        )
    except Exception as exc:
        logger.error("Failed to create session in DB: %s", exc, exc_info=True)
        raise HTTPException(status_code=503, detail=f"会话写入数据库失败: {exc}")

    # Install Worker proxy on the JWXT client so all JWXT API calls
    # go through the Cloudflare Worker (preserving the Worker's edge IP).
    if settings.jwxt_worker_proxy_origin and session.id:
        try:
            client.set_worker_proxy(session.id, settings.jwxt_worker_proxy_origin)
        except Exception as exc:
            logger.warning("Failed to install Worker proxy on session %s: %s", session.id[:8], exc)

    return {"sessionId": session.id, "isAdmin": bool(session.is_admin)}


# ─── Cron job endpoints (called by GitHub Actions scheduled workflow) ─────

@router.get("/cron/wechat-sync")
def wechat_sync_cron(request: Request, x_internal_key: str | None = Header(None)) -> dict:
    """同步公众号文章（由 GitHub Actions 定时调用；调用微信公开合集接口）。

    与 ecard-reminder 一样走 internal key 鉴权；未配置合集链接时直接跳过。
    """
    _verify_internal_key(x_internal_key)

    if not get_settings().wechat_album_url:
        return {"ok": True, "reason": "wechat album not configured", "added": 0}

    from app.wechat_service import sync_articles

    return {"ok": True, **sync_articles()}


@router.get("/cron/ecard-reminder")
def ecard_reminder_cron(request: Request, x_internal_key: str | None = Header(None)) -> dict:
    """Send low-balance push notifications from cached binding data.

    Does NOT call the school API (Vercel→school is too slow).
    Relies on `binding.last_summary_json` which is populated whenever
    a user refreshes their ecard page via /ecard/refresh.
    """
    _verify_internal_key(x_internal_key)

    if not get_settings().ecard_openid:
        return {"ok": True, "reason": "ecard not configured", "processed": 0}

    from datetime import datetime
    from zoneinfo import ZoneInfo

    from app.database import EcardBinding, PushRegistration, get_sync_session_factory
    from app.jobs import prepare_ecard_reminders
    from app.push import send_push, send_web_push_to_student

    factory = get_sync_session_factory()
    processed = 0
    notified = 0

    with factory() as db:
        bindings = (
            db.query(EcardBinding)
            .filter(EcardBinding.reminder_enabled.is_(True))
            .all()
        )
        # 与 jobs 轮询保持一致，按上海时区跨天重置
        today_key = datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()

        for binding in bindings:
            if not binding.last_summary_json:
                continue
            try:
                summary = json.loads(binding.last_summary_json)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(summary, dict):
                continue

            pending, _ = prepare_ecard_reminders(binding, summary, today_key)
            if not pending:
                continue

            for item_key, title, body in pending:
                live_payload = {
                    "id": f"ecard_cron:{binding.student_id}:{today_key}:{item_key}",
                    "type": "ecard_reminder",
                    "studentId": binding.student_id,
                    "itemKey": item_key,
                    "liveUpdate": True,
                    "style": "progress",
                    "shortCriticalText": "水电",
                }
                # Push notifications
                registration_ids = [
                    item.registration_id
                    for item in db.query(PushRegistration)
                    .filter(PushRegistration.student_id == binding.student_id)
                    .all()
                ]
                if registration_ids:
                    try:
                        send_push(registration_ids, title, body, live_payload)
                    except Exception as exc:
                        logger.warning("ecard cron: push failed for %s: %s",
                                       binding.student_id, exc)
                try:
                    send_web_push_to_student(binding.student_id, title, body, live_payload)
                except Exception:
                    pass
                notified += 1

            processed += 1

        try:
            db.commit()
        except Exception as exc:
            logger.error("ecard cron: commit failed: %s", exc)

    return {"ok": True, "processed": processed, "notified": notified}
