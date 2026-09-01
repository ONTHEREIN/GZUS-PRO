from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Request, Header, status

from app.config import get_settings
from app.database import IosPushToken, WebPushSubscription, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import IosPushTokenRequest, WebPushConfigResponse, WebPushSubscriptionRequest
from app.sessions import AppSession, student_id_of

router = APIRouter(prefix="/push", tags=["push"])


class _TestPushClient:
    def get_info(self) -> dict[str, str]:
        return {"studentId": "test-student"}

    def logout(self) -> None:
        pass


@router.get("/web/config", response_model=WebPushConfigResponse)
def get_web_push_config() -> WebPushConfigResponse:
    from app.push import web_push_public_key

    public_key = web_push_public_key()
    return WebPushConfigResponse(
        enabled=public_key is not None,
        publicKey=public_key,
    )


@router.post("/test-session")
def create_test_session(request: Request) -> dict[str, str]:
    if not get_settings().debug:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")
    session = request.app.state.sessions.create(_TestPushClient(), "测试用户")
    return {"sessionId": session.id}


@router.post("/web/register")
def register_web_push(
    payload: WebPushSubscriptionRequest,
    session: AppSession = Depends(require_session),
    user_agent: str | None = Header(None),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}

    expiration_time = None
    if payload.expiration_time:
        try:
            expiration_time = datetime.fromtimestamp(payload.expiration_time, tz=timezone.utc)
        except (ValueError, TypeError):
            pass
    
    factory = get_sync_session_factory()
    with factory() as db:
        # Check if subscription already exists
        existing = db.query(WebPushSubscription).filter(
            WebPushSubscription.endpoint == payload.endpoint
        ).first()
        
        if existing:
            existing.student_id = student_id
            existing.p256dh = payload.keys.p256dh
            existing.auth = payload.keys.auth
            existing.expiration_time = expiration_time
            existing.user_agent = user_agent
            existing.updated_at = datetime.now(timezone.utc)
        else:
            new_sub = WebPushSubscription(
                student_id=student_id,
                endpoint=payload.endpoint,
                p256dh=payload.keys.p256dh,
                auth=payload.keys.auth,
                expiration_time=expiration_time,
                user_agent=user_agent,
            )
            db.add(new_sub)
        
        db.commit()
    
    return {"status": "ok"}


@router.post("/web/unregister")
def unregister_web_push(
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    
    factory = get_sync_session_factory()
    with factory() as db:
        db.query(WebPushSubscription).filter(
            WebPushSubscription.student_id == student_id
        ).delete()
        db.commit()
    
    return {"status": "ok"}


@router.post("/ios/register")
def register_ios_push(
    payload: IosPushTokenRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}

    device_token = payload.device_token.lower()
    factory = get_sync_session_factory()
    with factory() as db:
        existing = db.query(IosPushToken).filter(
            IosPushToken.device_token == device_token,
            IosPushToken.environment == payload.environment,
        ).first()
        if existing:
            existing.student_id = student_id
            existing.updated_at = datetime.now(timezone.utc)
        else:
            db.add(IosPushToken(
                student_id=student_id,
                device_token=device_token,
                environment=payload.environment,
            ))
        db.commit()
    return {"status": "ok"}


@router.post("/ios/unregister")
def unregister_ios_push(
    payload: IosPushTokenRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}

    factory = get_sync_session_factory()
    with factory() as db:
        db.query(IosPushToken).filter(
            IosPushToken.student_id == student_id,
            IosPushToken.device_token == payload.device_token.lower(),
            IosPushToken.environment == payload.environment,
        ).delete()
        db.commit()
    return {"status": "ok"}


@router.post("/test")
async def test_push(
    request: Request,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    try:
        body = await request.json()
    except Exception:
        body = {}
    title = body.get("title", "软帮手通知")
    alert = body.get("body", "这是一条测试推送消息")
    url = body.get("url", "")
    msg_type = body.get("type", "new_notice")
    manager = request.app.state.ws_manager
    message = {
        "type": msg_type,
        "title": title,
        "body": alert,
        "url": url,
    }
    _copy_live_update_fields(body, message)
    await manager.send_to_session(session.id, message)
    from app.push import send_push_to_student

    student_id = student_id_of(session)
    if student_id:
        send_push_to_student(student_id, title, alert, message)
    return {"status": "ok", "sent_to": session.id[:8]}


@router.get("/poll")
def poll_push(
    request: Request,
    session: AppSession = Depends(require_session),
) -> dict[str, list[dict]]:
    try:
        manager = request.app.state.ws_manager
        return {"messages": manager.drain(session.id)}
    except Exception:
        import logging
        _logger = logging.getLogger(__name__)
        _logger.warning(
            "Error draining push messages for session %s", session.id[:8], exc_info=True
        )
        return {"messages": []}


def _copy_live_update_fields(source: dict, target: dict) -> None:
    for key in (
        "id",
        "liveUpdate",
        "style",
        "endTime",
        "shortCriticalText",
        "ongoing",
        "progressMax",
        "progressCurrent",
    ):
        if key in source:
            target[key] = source[key]
