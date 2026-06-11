import logging
from datetime import datetime, timedelta

from fastapi import Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

# How long a session can be idle before we consider the JWXT session
# potentially expired.  JWXT sessions typically expire after ~30 min of
# inactivity, so we proactively mark sessions as stale after 25 minutes.
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)


def _inject_worker_cookies(session: AppSession, request: Request) -> None:
    """Override session client cookies with fresh ones from the Cloudflare Worker.

    The Worker edge holds the live JWXT cookies (IP-bounded to the Worker's IP).
    It injects them as Cookie / X-Ehall-Cookies headers on every proxied request.
    We must apply them to the session's live client objects so that subsequent
    API calls use the fresh cookies instead of the DB-stored stale ones.
    """
    worker_auth = request.headers.get("X-Worker-Auth")
    if not worker_auth:
        return

    cookie_header = request.headers.get("Cookie")
    if cookie_header and session.client is not None:
        try:
            from app.school_client import SchoolSdkClient
            if isinstance(session.client, SchoolSdkClient):
                session.client.apply_cookie_header(cookie_header)
        except Exception:
            logger.warning("Failed to inject Worker JWXT cookies into session client", exc_info=True)

    ehall_cookie_header = request.headers.get("X-Ehall-Cookies")
    if ehall_cookie_header and session.ehall_client is not None:
        try:
            from app.ehall_client import EhallClient
            if isinstance(session.ehall_client, EhallClient):
                # Update the internal cookies dict and the live httpx client
                new_cookies = {}
                for part in ehall_cookie_header.split(";"):
                    part = part.strip()
                    if "=" in part:
                        key, _, value = part.partition("=")
                        key = key.strip()
                        value = value.strip()
                        if key:
                            new_cookies[key] = value
                session.ehall_client._cookies.update(new_cookies)
                http_client = getattr(session.ehall_client, "_http_client", None)
                if http_client is not None and not getattr(http_client, "is_closed", True):
                    for key, value in new_cookies.items():
                        http_client.cookies.set(key, value)
        except Exception:
            logger.warning("Failed to inject Worker ehall cookies into session client", exc_info=True)


def require_session(
    request: Request, x_session_id: str | None = Header(default=None, alias="X-Session-Id")
) -> AppSession:
    if not x_session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="登录已过期，请重新登录")
    session = request.app.state.sessions.get(x_session_id, touch=False)
    if session is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期")

    # Proactively check if the session has been idle too long.
    # The JWXT system typically invalidates its own session after ~30 min
    # of inactivity.  If our session has been idle for longer than the
    # threshold, the downstream proxy_request will almost certainly fail.
    # By detecting this early, we trigger the frontend's relogin flow
    # immediately rather than after a slow, doomed round-trip to JWXT.
    idle_time = datetime.now() - session.last_active_at
    if idle_time > SESSION_IDLE_STALE_THRESHOLD:
        logger.info(
            "Session %s idle for %ds (threshold=%ds), marking as stale",
            session.id[:8],
            int(idle_time.total_seconds()),
            int(SESSION_IDLE_STALE_THRESHOLD.total_seconds()),
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )

    # Inject fresh cookies from the Cloudflare Worker edge.
    # This must happen AFTER session retrieval but BEFORE the session is
    # used for any API call, because the DB-stored cookies are IP-bounded
    # to the Worker's edge and won't work from Vercel's IP.
    _inject_worker_cookies(session, request)

    request.app.state.sessions.touch(session.id)
    return session
