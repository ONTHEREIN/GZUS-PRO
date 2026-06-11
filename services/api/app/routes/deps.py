import logging
from datetime import datetime, timedelta

from fastapi import Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

# How long a session can be idle before we consider the JWXT session
# potentially expired.  JWXT sessions typically expire after ~30 min of
# inactivity.  When no Worker cookie injection is available, we attempt
# auto-relogin at this threshold instead of returning 401 immediately.
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)


def _inject_worker_cookies(session: AppSession, request: Request) -> bool:
    """Override session client cookies with fresh ones from the Cloudflare Worker.

    Returns True if at least JWXT cookies were injected, False otherwise.
    The return value signals whether the Worker edge is actively managing
    this session's cookies.
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
    if cookie_header and session.client is not None:
        try:
            from app.school_client import SchoolSdkClient

            if isinstance(session.client, SchoolSdkClient):
                logger.info(
                    "Session %s: injecting Worker JWXT cookies (%d chars, %d keys) into SchoolSdkClient",
                    session.id[:8],
                    len(cookie_header),
                    cookie_header.count("="),
                )
                session.client.apply_cookie_header(cookie_header)
                injected = True
            else:
                logger.warning(
                    "Session %s: client is %s, not SchoolSdkClient — cannot inject JWXT cookies",
                    session.id[:8],
                    type(session.client).__name__,
                )
        except Exception:
            logger.warning(
                "Failed to inject Worker JWXT cookies into session client",
                exc_info=True,
            )
    elif not cookie_header:
        logger.warning(
            "Session %s: X-Worker-Auth present but no Cookie header from Worker",
            session.id[:8],
        )
    elif session.client is None:
        logger.warning(
            "Session %s: Cookie header present but session.client is None",
            session.id[:8],
        )

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
                logger.info(
                    "Session %s: injecting Worker ehall cookies (%d keys) into EhallClient",
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
        logger.debug(
            "Session %s: no X-Ehall-Cookies header from Worker",
            session.id[:8],
        )
    elif session.ehall_client is None:
        logger.debug(
            "Session %s: X-Ehall-Cookies present but session.ehall_client is None",
            session.id[:8],
        )

    return injected


def _try_auto_relogin(session: AppSession, request: Request) -> bool:
    """Attempt to refresh the session by re-authenticating via CAS from Vercel's IP.

    This is the fallback when the Cloudflare Worker edge cannot inject fresh
    JWXT cookies (e.g. Worker cold-start lost the in-memory localSessions Map).
    By performing CAS login from Vercel's own IP, we obtain cookies that are
    IP-bounded to Vercel — so they will actually work for subsequent API calls.

    Returns True if the relogin succeeded and session.client was replaced
    with a freshly authenticated client.
    """
    from urllib.parse import quote as url_quote

    from app.cas_auto_login import CasAutoLogin
    from app.config import get_settings
    from app.school_client import SchoolSdkClient
    from app.sessions import decrypt_credentials

    settings = get_settings()

    encrypted_creds = getattr(session, "encrypted_credentials", None)
    if not encrypted_creds:
        logger.info(
            "Session %s: no encrypted credentials stored — cannot auto-relogin",
            session.id[:8],
        )
        return False

    try:
        account, password = decrypt_credentials(
            encrypted_creds,
            settings.credential_encryption_key,
            ttl_seconds=settings.ehall_session_ttl_hours * 3600,
        )
    except Exception as exc:
        logger.warning(
            "Session %s: failed to decrypt stored credentials: %s",
            session.id[:8],
            exc,
        )
        return False

    logger.info(
        "Session %s: attempting auto-relogin for account=%s from Vercel IP",
        session.id[:8],
        account,
    )

    try:
        cas_url = (
            f"{settings.cas_login_url}?service="
            f"{url_quote(settings.jwxt_sso_service_url, safe='')}"
        )
        cas_auto_login = CasAutoLogin(
            cas_url=cas_url,
            ehall_url=settings.ehall_base_url,
            timeout=settings.cas_login_timeout_seconds,
        )
        result = cas_auto_login.auto_login(account, password)

        if result.error:
            logger.warning(
                "Session %s: auto-relogin CAS failed: %s",
                session.id[:8],
                result.error,
            )
            return False

        # Build fresh SchoolSdkClient with Vercel-IP-bounded cookies
        client = SchoolSdkClient(
            base_url=settings.jw_base_url,
            timeout_seconds=settings.request_timeout_seconds,
            httpx_client=result.httpx_client,
        )
        try:
            student_name = client.login_with_cookies(
                result.cookies, account=result.account
            )
            if student_name:
                session.student_name = student_name
        except Exception as exc:
            logger.warning(
                "Session %s: login_with_cookies failed after CAS: %s",
                session.id[:8],
                exc,
            )
            return False

        # Replace session client with freshly authenticated one
        session.client = client

        # Persist new cookies to DB so future cold-starts have them
        jwxt_cookies = result.cookies or ""
        ehall_cookies = result.ehall_cookies or ""
        ehall_auth_token = result.ehall_auth_token or ""

        try:
            request.app.state.sessions.update(
                session.id,
                jwxt_cookies=jwxt_cookies,
                ehall_cookies=ehall_cookies,
                ehall_auth_token=ehall_auth_token,
                student_name=session.student_name,
            )
        except Exception:
            logger.warning(
                "Session %s: failed to persist refreshed cookies to DB",
                session.id[:8],
                exc_info=True,
            )

        # Rebuild ehall client if available
        if ehall_cookies or ehall_auth_token:
            try:
                from app.ehall_client import EhallClient

                session.ehall_client = EhallClient(
                    base_url=settings.ehall_base_url,
                    cookies=ehall_cookies,
                    auth_token=ehall_auth_token,
                    timeout_seconds=settings.request_timeout_seconds,
                )
            except Exception:
                logger.warning(
                    "Session %s: failed to rebuild ehall client after relogin",
                    session.id[:8],
                )

        logger.info(
            "Session %s: auto-relogin SUCCEEDED — cookies now bound to Vercel IP",
            session.id[:8],
        )
        return True

    except Exception as exc:
        logger.error(
            "Session %s: auto-relogin unexpected error: %s",
            session.id[:8],
            exc,
            exc_info=True,
        )
        return False


def require_session(
    request: Request,
    x_session_id: str | None = Header(default=None, alias="X-Session-Id"),
) -> AppSession:
    """FastAPI dependency: resolve and validate the user session.

    Resolution order:
    1. Load session from DB by X-Session-Id header.
    2. Inject fresh JWXT cookies from Cloudflare Worker if available.
    3. If Worker cookies are NOT available (X-Worker-Auth missing) and the
       session has been idle beyond the stale threshold, attempt an automatic
       CAS relogin from Vercel's own IP using stored encrypted credentials.
       This bypasses the Worker's ephemeral in-memory localSessions Map,
       which is lost on Worker cold-start / eviction.
    4. Return the session (ready for use) or raise 401.
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

    idle_time = datetime.now() - session.last_active_at
    logger.info(
        "Session %s resolved for %s (client=%s, ehall=%s, idle=%ds)",
        session.id[:8],
        request.url.path,
        type(session.client).__name__ if session.client else "None",
        type(session.ehall_client).__name__ if session.ehall_client else "None",
        int(idle_time.total_seconds()),
    )

    # Step 1: Inject fresh cookies from the Cloudflare Worker edge.
    # Worker cookies are IP-bounded to the Worker's edge location and are
    # the most reliable.  This must happen before any API call.
    worker_injected = _inject_worker_cookies(session, request)

    # Step 2: If the Worker did NOT inject cookies, the DB-stored cookies
    # may be stale (IP-bounded to a previous Worker instance).  Attempt
    # auto-relogin from Vercel's own IP when the session has been idle
    # long enough that JWXT expiration is likely.
    if not worker_injected and idle_time > SESSION_IDLE_STALE_THRESHOLD:
        logger.info(
            "Session %s: no Worker cookies + idle %ds > threshold %ds — attempting auto-relogin",
            session.id[:8],
            int(idle_time.total_seconds()),
            int(SESSION_IDLE_STALE_THRESHOLD.total_seconds()),
        )
        if not _try_auto_relogin(session, request):
            logger.warning(
                "Session %s: auto-relogin failed, returning 401",
                session.id[:8],
            )
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="会话已过期，请重新登录",
            )

    # Step 3: Touch and return
    request.app.state.sessions.touch(session.id)
    return session
