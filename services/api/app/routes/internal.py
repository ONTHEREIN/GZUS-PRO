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

class CreateSessionRequest(BaseModel):
    account: str
    cookies: str
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
        password = rsa_key_manager.decrypt(payload.encrypted_password)
        return {"password": password}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"密码解密失败: {exc}")


@router.post("/create-session")
def create_session_endpoint(
    payload: CreateSessionRequest,
    request: Request,
    x_internal_key: str | None = Header(None),
) -> dict:
    """Create a session from CAS login result (called by Cloudflare Worker)."""
    _verify_internal_key(x_internal_key)
    sessions = request.app.state.sessions
    settings = get_settings()

    # Create SchoolSdkClient with the cookies from CAS login
    client = SchoolSdkClient(
        base_url=settings.jw_base_url,
        timeout_seconds=settings.request_timeout_seconds,
    )
    try:
        student_name = client.login_with_cookies(payload.cookies, payload.account)
    except Exception as exc:
        logger.warning("login_with_cookies failed in create-session: %s", exc)
        student_name = payload.student_name

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

    session = sessions.create(
        client,
        student_name=student_name or payload.student_name,
        ehall_client=ehall_client,
    )

    return {"sessionId": session.id}
