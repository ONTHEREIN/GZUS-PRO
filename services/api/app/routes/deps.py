from fastapi import Header, HTTPException, Request, status

from app.sessions import AppSession


def require_session(
    request: Request, x_session_id: str | None = Header(default=None, alias="X-Session-Id")
) -> AppSession:
    if not x_session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="缺少会话")
    session = request.app.state.sessions.get(x_session_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期")
    return session
