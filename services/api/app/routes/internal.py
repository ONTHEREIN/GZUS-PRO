"""Internal API endpoints for Cloudflare Worker.

These endpoints are called by the Cloudflare Worker running on the edge
to offload operations that require the Python runtime (OCR, SDK, sessions).
They are protected by an internal API key.
"""
from __future__ import annotations

import base64
import logging

from fastapi import APIRouter, Header, HTTPException, Request, status
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
    password: str | None = None  # for generating Fernet credential token server-side
    ehall_cookies: str | None = None
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

    # Generate Fernet-encrypted credential token for server-side auto-relogin.
    # This is separate from the AES-GCM token the Worker gives to the frontend.
    # Vercel needs Fernet tokens for its own transparent session recovery.
    encrypted_credentials = None
    if payload.password:
        try:
            from app.sessions import encrypt_credentials
            encrypted_credentials = encrypt_credentials(
                payload.account,
                payload.password,
                settings.credential_encryption_key,
            )
            logger.debug("create-session: generated Fernet credential for account=%s", payload.account)
        except Exception as exc:
            logger.warning("Failed to encrypt credentials for session: %s", exc)

    # Create ehall client if ehall cookies are available
    ehall_client = None
    if payload.ehall_cookies:
        try:
            from app.ehall_client import EhallClient
            ehall_client = EhallClient(
                base_url=settings.ehall_base_url,
                cookies=payload.ehall_cookies,
            )
        except Exception as exc:
            logger.warning("Failed to create ehall client: %s", exc)

    session = None
    try:
        session = sessions.create(
            client,
            student_name=student_name or payload.student_name,
            ehall_client=ehall_client,
            encrypted_credentials=encrypted_credentials,
        )
    except Exception as exc:
        logger.error("Failed to create session in DB: %s", exc, exc_info=True)
        raise HTTPException(status_code=503, detail=f"会话写入数据库失败: {exc}")

    return {"sessionId": session.id, "credentialToken": encrypted_credentials}
