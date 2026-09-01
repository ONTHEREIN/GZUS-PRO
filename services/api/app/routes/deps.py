import logging

from fastapi import Depends, Header, HTTPException, Request, status

from app.sessions import AppSession

logger = logging.getLogger(__name__)

def require_session(
    request: Request,
    x_session_id: str | None = Header(default=None, alias="X-Session-Id"),
) -> AppSession:
    """解析持久化会话并拒绝已撤销会话。"""
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
            detail="当前设备已被管理员下线，请重新验证登录",
        )
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
