import logging
from datetime import datetime, timedelta, timezone

from fastapi import Depends, Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

# 教务系统会话通常约 30 分钟失效；在本机服务端主动提示客户端重新登录。
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)


def require_session(
    request: Request,
    x_session_id: str | None = Header(default=None, alias="X-Session-Id"),
) -> AppSession:
    """解析持久化会话并拒绝已撤销或长期空闲的会话。"""
    if not x_session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="登录已过期，请重新登录")

    method = getattr(request, "method", "GET").upper()
    try:
        session = request.app.state.sessions.get(
            x_session_id,
            touch=False,
            fresh=method in {"POST", "PATCH", "DELETE"},
        )
    except TypeError:
        session = request.app.state.sessions.get(x_session_id, touch=False)
    if session is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期")
    if session.revoked_at is not None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="账号已在其他设备登录，请重新登录",
        )

    idle_time = datetime.now(timezone.utc).replace(tzinfo=None) - session.last_active_at
    if idle_time > SESSION_IDLE_STALE_THRESHOLD:
        logger.info(
            "session_idle_expired",
            extra={"session_id_prefix": session.id[:8], "idle_seconds": int(idle_time.total_seconds())},
        )
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期，请重新登录")
    request.app.state.sessions.touch(session.id)
    return session


def require_admin(session: AppSession = Depends(require_session)) -> AppSession:
    """要求当前会话的学号位于管理员白名单。"""
    if not session.is_admin:
        logger.warning(
            "admin_permission_denied",
            extra={"session_id_prefix": session.id[:8], "student_account": session.student_account},
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="无管理权限")
    return session
