import logging
from datetime import datetime, timedelta

from fastapi import Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

# How long a session can be idle before we consider the JWXT session
# potentially expired.  JWXT sessions typically expire after ~30 min of
# inactivity, so we proactively mark sessions as stale after 25 minutes.
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)


def require_session(
    request: Request, x_session_id: str | None = Header(default=None, alias="X-Session-Id")
) -> AppSession:
    if not x_session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="缺少会话")
    session = request.app.state.sessions.get(x_session_id)
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

    return session
