import json
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, Request, Header, status

from app.config import get_settings
from app.database import (
    IosLiveActivityToken,
    IosPushToken,
    WebPushSubscription,
    get_sync_session_factory,
)
from app.routes.deps import require_session
from app.schemas import (
    IosCourseScheduleSyncRequest,
    IosLiveActivityTokenRequest,
    IosPushTokenRequest,
    IosLiveActivityTokenUnregisterRequest,
    IosLiveActivityTokensUnregisterRequest,
    WebPushConfigResponse,
    WebPushSubscriptionRequest,
    WebPushSubscriptionUnregisterRequest,
)
from app.sessions import AppSession, student_id_of

router = APIRouter(prefix="/push", tags=["push"])

_LEGACY_ACTIVITY_TOKEN_TTL = timedelta(hours=6)
_ACTIVITY_EXPIRY_GRACE = timedelta(minutes=15)


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
    payload: WebPushSubscriptionUnregisterRequest | None = None,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    
    factory = get_sync_session_factory()
    with factory() as db:
        query = db.query(WebPushSubscription).filter(
            WebPushSubscription.student_id == student_id
        )
        if payload is not None and payload.endpoint:
            query = query.filter(WebPushSubscription.endpoint == payload.endpoint)
        query.delete(synchronize_session=False)
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
            if existing.student_id != student_id:
                # 设备令牌转移到新账号时，旧账号的本地课程覆盖不能随令牌迁移。
                existing.course_local_event_keys_json = None
                existing.course_local_valid_until = None
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


@router.post("/ios/course-schedule")
def sync_ios_course_schedule(
    payload: IosCourseScheduleSyncRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    """记录当前 iOS 设备已经由系统本地通知覆盖的课程事件。"""
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    device_token = payload.device_token.lower()
    with get_sync_session_factory()() as db:
        row = db.query(IosPushToken).filter_by(
            device_token=device_token,
            environment=payload.environment,
        ).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="请先注册 iOS 普通推送令牌")
        if row.student_id != student_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="设备令牌不属于当前账号")
        row.course_local_event_keys_json = json.dumps(
            sorted(set(payload.event_keys)), ensure_ascii=False, separators=(",", ":")
        )
        row.course_local_valid_until = payload.valid_until
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
    return {"status": "ok"}


@router.post("/ios/live-activity-tokens")
def register_ios_live_activity_token(
    payload: IosLiveActivityTokenRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    if payload.token_type == "activity" and not payload.activity_id:
        raise HTTPException(status_code=422, detail="activity token 缺少 activityId")

    token = payload.token.lower()
    now = datetime.now(timezone.utc)
    expires_at = None
    if payload.token_type == "activity":
        if payload.expires_at is None:
            expires_at = now + _LEGACY_ACTIVITY_TOKEN_TTL
        else:
            expires_at = payload.expires_at
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            expires_at = expires_at.astimezone(timezone.utc) + _ACTIVITY_EXPIRY_GRACE
    factory = get_sync_session_factory()
    with factory() as db:
        if payload.device_id:
            stale_rows = db.query(IosLiveActivityToken).filter_by(
                student_id=student_id,
                environment=payload.environment,
                token_type=payload.token_type,
                device_id=payload.device_id,
            )
            if payload.token_type == "activity":
                stale_rows = stale_rows.filter(IosLiveActivityToken.activity_id == payload.activity_id)
            for stale_row in stale_rows.all():
                if stale_row.token != token:
                    db.delete(stale_row)
        existing = db.query(IosLiveActivityToken).filter(
            IosLiveActivityToken.token == token,
            IosLiveActivityToken.environment == payload.environment,
            IosLiveActivityToken.token_type == payload.token_type,
        ).first()
        if existing:
            existing.student_id = student_id
            existing.activity_id = payload.activity_id
            existing.activity_type = payload.activity_type
            existing.device_id = payload.device_id
            existing.expires_at = expires_at
            existing.updated_at = now
        else:
            db.add(IosLiveActivityToken(
                student_id=student_id,
                token_type=payload.token_type,
                token=token,
                environment=payload.environment,
                activity_id=payload.activity_id,
                activity_type=payload.activity_type,
                device_id=payload.device_id,
                expires_at=expires_at,
            ))
        db.commit()
    return {"status": "ok"}


@router.post("/ios/live-activity-tokens/activity/unregister")
def unregister_ios_live_activity_token(
    payload: IosLiveActivityTokenUnregisterRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    factory = get_sync_session_factory()
    with factory() as db:
        db.query(IosLiveActivityToken).filter_by(
            student_id=student_id,
            token_type="activity",
            environment=payload.environment,
            activity_id=payload.activity_id,
            device_id=payload.device_id,
        ).delete(synchronize_session=False)
        db.commit()
    return {"status": "ok"}


@router.post("/ios/live-activity-tokens/unregister")
def unregister_ios_live_activity_tokens(
    payload: IosLiveActivityTokensUnregisterRequest | None = None,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    student_id = student_id_of(session)
    if not student_id:
        return {"status": "error", "message": "Student ID not found"}
    factory = get_sync_session_factory()
    with factory() as db:
        query = db.query(IosLiveActivityToken).filter(
            IosLiveActivityToken.student_id == student_id
        )
        if payload is not None and payload.device_id:
            query = query.filter(IosLiveActivityToken.device_id == payload.device_id)
        query.delete(synchronize_session=False)
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
    delivered_channels = 0
    regular_channels = 0
    live_activity_channels = 0
    if student_id:
        from app.push import PushDeliveryResult

        result = send_push_to_student(student_id, title, alert, message)
        if not isinstance(result, PushDeliveryResult):
            raise RuntimeError("推送通道返回值无效")
        regular_channels = result.regular_delivered
        live_activity_channels = result.live_activity_delivered
        delivered_channels = result.total_channels
    return {
        "status": "ok",
        "sent_to": session.id[:8],
        "delivered_channels": str(delivered_channels),
        "regular_channels": str(regular_channels),
        "live_activity_channels": str(live_activity_channels),
        "delivery_status": "delivered" if regular_channels > 0 else "queued_only",
    }


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
        "targetTab",
        "liveUpdate",
        "liveEvent",
        "style",
        "startTime",
        "endTime",
        "shortCriticalText",
        "ongoing",
        "progressMax",
        "progressCurrent",
        "progress",
    ):
        if key in source:
            target[key] = source[key]
