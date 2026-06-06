from fastapi import APIRouter, Depends, Request

from app.database import PushRegistration, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import PushRegisterRequest
from app.sessions import AppSession

router = APIRouter(prefix="/push", tags=["push"])


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
    body = await request.json()
    title = body.get("title", "GZUS-PRO 通知")
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
    await manager.send_to_session(session.id, message)
    return {"status": "ok", "sent_to": session.id[:8]}


@router.get("/poll")
def poll_push(
    request: Request,
    session: AppSession = Depends(require_session),
) -> dict[str, list[dict]]:
    manager = request.app.state.ws_manager
    return {"messages": manager.drain(session.id)}


@router.post("/test-ws")
async def test_ws_broadcast(
    request: Request,
) -> dict:
    body = await request.json()
    title = body.get("title", "GZUS-PRO 通知")
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
    online_count = len(manager.active)
    await manager.broadcast(message)
    return {"status": "ok", "online_connections": online_count}


@router.post("/test-session")
def create_test_session(
    request: Request,
) -> dict:
    from app.school_client import SchoolSdkClient
    sessions = request.app.state.sessions
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    session = sessions.create(client, "测试用户")
    return {"sessionId": session.id, "studentName": session.student_name}


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
