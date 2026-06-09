from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Request, Header, status

from app.config import get_settings
from app.database import PushRegistration, WebPushSubscription, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import PushRegisterRequest, WebPushConfigResponse, WebPushSubscriptionRequest
from app.sessions import AppSession

router = APIRouter(prefix="/push", tags=["push"])


class _TestPushClient:
    def get_info(self) -> dict[str, str]:
        return {"studentId": "test-student"}

    def logout(self) -> None:
        pass


@router.get("/web/config", response_model=WebPushConfigResponse)
def get_web_push_config() -> WebPushConfigResponse:
    settings = get_settings()
    enabled = bool(settings.web_push_vapid_public_key and settings.web_push_vapid_private_key)
    return WebPushConfigResponse(
        enabled=enabled,
        publicKey=settings.web_push_vapid_public_key if enabled else None
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
    try:
        info = session.client.get_info()
    except Exception:
        return {"status": "error", "message": "Cannot get student info"}
    
    student_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
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
    try:
        info = session.client.get_info()
    except Exception:
        return {"status": "error", "message": "Cannot get student info"}
    
    student_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    
    factory = get_sync_session_factory()
    with factory() as db:
        db.query(WebPushSubscription).filter(
            WebPushSubscription.student_id == student_id
        ).delete()
        db.commit()
    
    return {"status": "ok"}


@router.post("/register")
def register_push(
    payload: PushRegisterRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    session.push_registration_id = payload.registration_id
    session.push_platform = payload.platform
    _upsert_push_registration(session, payload.registration_id, payload.platform)
    return {"status": "ok"}


@router.post("/unregister")
def unregister_push(
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    registration_id = session.push_registration_id
    session.push_registration_id = None
    session.push_platform = None
    if registration_id:
        factory = get_sync_session_factory()
        with factory() as db:
            db.query(PushRegistration).filter(
                PushRegistration.registration_id == registration_id
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
    title = body.get("title", "OneGZUS 通知")
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
    return {"status": "ok", "sent_to": session.id[:8]}


@router.get("/poll")
def poll_push(
    request: Request,
    session: AppSession = Depends(require_session),
) -> dict[str, list[dict]]:
    manager = request.app.state.ws_manager
    return {"messages": manager.drain(session.id)}


def _upsert_push_registration(session: AppSession, registration_id: str, platform: str) -> None:
    try:
        info = session.client.get_info()
    except Exception:
        return
    student_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
    if not student_id:
        return
    factory = get_sync_session_factory()
    with factory() as db:
        item = (
            db.query(PushRegistration)
            .filter(PushRegistration.registration_id == registration_id)
            .first()
        )
        if item is None:
            item = PushRegistration(
                student_id=student_id,
                registration_id=registration_id,
                platform=platform,
            )
            db.add(item)
        else:
            item.student_id = student_id
            item.platform = platform
        db.commit()


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
