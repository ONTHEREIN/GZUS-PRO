import logging
from datetime import datetime, timedelta, timezone

from fastapi import Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

# How long a session can be idle before we consider the JWXT session
# potentially expired.  JWXT sessions typically expire after ~30 min of
# inactivity.  We proactively return 401 so the frontend can relogin
# before the user notices a slow failed round-trip to JWXT.
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)


def _inject_worker_cookies(session: AppSession, request: Request) -> bool:
    """Override session client cookies with fresh ones from the Cloudflare Worker.

    Returns True if at least JWXT cookies were injected, False otherwise.
    """
    worker_auth = request.headers.get("X-Worker-Auth")
    if not worker_auth:
        logger.debug(
            "Session %s: no X-Worker-Auth header, skipping cookie injection",
            session.id[:8],
        )
        return False

    injected = False

    cookie_header = request.headers.get("Cookie")
    student_account = request.headers.get("X-Student-Account")
    if cookie_header:
        if session.client is not None:
            try:
                from app.school_client import SchoolSdkClient

                if isinstance(session.client, SchoolSdkClient):
                    logger.info(
                        "Session %s: injecting Worker JWXT cookies (%d chars, %d keys)",
                        session.id[:8],
                        len(cookie_header),
                        cookie_header.count("="),
                    )
                    session.client.apply_cookie_header(cookie_header)
                    # Also restore account on existing client if available
                    if student_account and not getattr(session.client, "_account", None):
                        session.client._account = student_account
                        logger.info(
                            "Session %s: restored account %s from Worker header",
                            session.id[:8],
                            student_account,
                        )
                    injected = True
                else:
                    logger.warning(
                        "Session %s: client is %s, not SchoolSdkClient",
                        session.id[:8],
                        type(session.client).__name__,
                    )
            except Exception:
                logger.warning(
                    "Failed to inject Worker JWXT cookies into session client",
                    exc_info=True,
                )
        else:
            # session.client is None (DB cookies were stale/empty).
            # Recovery: build a fresh client from Worker-injected cookies.
            logger.warning(
                "Session %s: Cookie header present but session.client is None — attempting recovery",
                session.id[:8],
            )
            try:
                from app.school_client import SchoolSdkClient
                from app.config import get_settings

                settings = get_settings()
                new_client = SchoolSdkClient(
                    settings.jw_base_url,
                    timeout_seconds=settings.request_timeout_seconds,
                    session_id=session.id,
                    worker_proxy_origin=settings.jwxt_worker_proxy_origin or None,
                )
                new_client.login_with_cookies(cookie_header, student_account or "", validate=False)
                session.client = new_client
                injected = True
                logger.info(
                    "Session %s: RECOVERED — built new client from Worker cookies (account=%s)",
                    session.id[:8],
                    student_account or "(none)",
                )
            except Exception:
                logger.warning(
                    "Session %s: recovery failed",
                    session.id[:8],
                    exc_info=True,
                )
    elif not cookie_header:
        logger.warning(
            "Session %s: X-Worker-Auth present but no Cookie header from Worker",
            session.id[:8],
        )

    ehall_cookie_header = request.headers.get("X-Ehall-Cookies")
    if ehall_cookie_header and session.ehall_client is not None:
        try:
            from app.ehall_client import EhallClient

            if isinstance(session.ehall_client, EhallClient):
                new_cookies = {}
                for part in ehall_cookie_header.split(";"):
                    part = part.strip()
                    if "=" in part:
                        key, _, value = part.partition("=")
                        key = key.strip()
                        value = value.strip()
                        if key:
                            new_cookies[key] = value
                logger.info(
                    "Session %s: injecting Worker ehall cookies (%d keys)",
                    session.id[:8],
                    len(new_cookies),
                )
                session.ehall_client._cookies.update(new_cookies)
                http_client = getattr(session.ehall_client, "_http_client", None)
                if http_client is not None and not getattr(http_client, "is_closed", True):
                    for key, value in new_cookies.items():
                        http_client.cookies.set(key, value)
        except Exception:
            logger.warning(
                "Failed to inject Worker ehall cookies into session client",
                exc_info=True,
            )
    elif not ehall_cookie_header:
        logger.debug("Session %s: no X-Ehall-Cookies header from Worker", session.id[:8])
    elif session.ehall_client is None:
        logger.debug(
            "Session %s: X-Ehall-Cookies present but session.ehall_client is None",
            session.id[:8],
        )

    return injected


def require_session(
    request: Request,
    x_session_id: str | None = Header(default=None, alias="X-Session-Id"),
) -> AppSession:
    """FastAPI dependency: resolve and validate the user session.

    1. Load session from DB.
    2. Inject fresh JWXT cookies from Cloudflare Worker (edge).
       The Worker stores cookies in memory + Cloudflare KV for
       cross-instance persistence.
    3. If no Worker cookies AND session idle > threshold → 401.
       The frontend will trigger a Worker-side relogin (fast, near China).
    4. Touch and return.
    """
    if not x_session_id:
        logger.warning(
            "require_session: no X-Session-Id header in request to %s",
            request.url.path,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录已过期，请重新登录",
        )

    session = request.app.state.sessions.get(x_session_id, touch=False)
    if session is None:
        logger.warning(
            "require_session: session %s not found in DB for %s",
            x_session_id[:8],
            request.url.path,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期",
        )

    if session.revoked_at is not None:
        logger.info(
            "require_session: session %s revoked for %s (reason=%s)",
            x_session_id[:8],
            request.url.path,
            session.revoked_reason,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="账号已在其他设备登录，请重新登录",
        )

    idle_time = datetime.now(timezone.utc).replace(tzinfo=None) - session.last_active_at
    logger.info(
        "Session %s resolved for %s (client=%s, ehall=%s, idle=%ds)",
        session.id[:8],
        request.url.path,
        type(session.client).__name__ if session.client else "None",
        type(session.ehall_client).__name__ if session.ehall_client else "None",
        int(idle_time.total_seconds()),
    )

    # Inject fresh cookies from the Cloudflare Worker edge.
    # Worker cookies come from memory (fast) or Cloudflare KV (cross-instance).
    worker_injected = _inject_worker_cookies(session, request)

    # If Worker couldn't inject cookies AND the session has been idle
    # beyond the JWXT expiration window, return 401 proactively.
    # The frontend will trigger a Worker-side relogin, which is fast
    # (edge near China) and creates fresh IP-bounded cookies.
    if not worker_injected and idle_time > SESSION_IDLE_STALE_THRESHOLD:
        logger.info(
            "Session %s: no Worker cookies + idle %ds > %ds — returning 401 for frontend relogin",
            session.id[:8],
            int(idle_time.total_seconds()),
            int(SESSION_IDLE_STALE_THRESHOLD.total_seconds()),
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )

    # Touch and return
    request.app.state.sessions.touch(session.id)
    return session
