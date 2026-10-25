"""微信小程序专用入口。

学校账号密码在服务端完成认证，客户端只保存短期会话 ID。用户在登录时明确
授权后，可将加密凭据保存到服务端用于后台检测。登录响应过滤教务 Cookie、
办事大厅 Token 与长期凭据，避免它们落入小程序本地存储。
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database import WechatBinding, get_sync_session_factory
from app.mini_notification_models import MiniProgramLoginRequest
from app.routes.auth import auto_login
from app.routes.deps import require_session
from app.schemas import (
    AutoLoginRequest,
    MiniProgramAuthResponse,
    WechatBindingResponse,
    WechatBindingStatus,
    WechatCodeRequest,
)
from app.rate_limit import limiter
from app.school_client import AuthenticationError
from app.school_session_service import (
    SchoolSessionUnavailableError,
    account_school_session_lock,
    load_shared_school_clients,
    release_if_unused,
)
from app.sessions import AppSession, student_id_of
from app.wechat_identity import (
    WechatIdentity,
    WechatIdentityError,
    WechatNotConfiguredError,
    encrypt_openid,
    exchange_code,
    openid_fingerprint,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/mini", tags=["mini-program"])


def _as_text(value: object) -> str:
    """把上游可能缺失的身份字段归一化成字符串。"""
    return value if isinstance(value, str) else ""


@router.post("/auth/login", response_model=MiniProgramAuthResponse)
@limiter.limit("10/minute")
def login(payload: MiniProgramLoginRequest, request: Request) -> MiniProgramAuthResponse:
    """使用现有学校认证链路创建小程序短期会话。"""
    identity: WechatIdentity | None = None
    if payload.background_consent:
        if payload.code is None:
            raise HTTPException(status_code=422, detail="后台检测授权需要当前微信登录凭证")
        identity = _exchange_or_raise(payload.code)
    result = auto_login(AutoLoginRequest.model_validate(payload.model_dump()), request)

    session_id = result.get("sessionId")
    if not isinstance(session_id, str) or not session_id:
        # 没有会话客户端什么都做不了，这里必须失败。但要用 HTTPException：
        # 裸 RuntimeError 会被全局处理器变成 500「服务器内部错误」，
        # 既拿不到有用信息，也不符合「上游没给出会话」的语义。
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="学校系统未建立有效会话，请稍后重试",
        )

    # 姓名与学号是**尽力而为**的字段：`login_with_cookies` 的签名就是 `str | None`，
    # 拿不到姓名属于上游正常情况，不能因此让整个登录失败——否则用户完全用不了，
    # 而且 auto_login 里已经创建好的会话会白白泄漏（客户端拿不到 sessionId，无法复用）。
    # 小程序也不显示这两个字段：姓名/学号以 /me 的返回为准。
    student_name = _as_text(result.get("studentName"))
    student_id = _as_text(result.get("studentId"))
    if not student_name or not student_id:
        logger.warning(
            "mini program login: 身份字段缺失 student=%s has_name=%s has_id=%s",
            payload.account,
            bool(student_name),
            bool(student_id),
        )

    if identity is not None:
        from app.routes.mini_notifications import save_background_authorization

        token = result.get("credentialToken")
        if not isinstance(token, str) or not token:
            raise HTTPException(status_code=502, detail="学校登录未生成有效的后台授权凭据")
        persist_wechat_binding(student_id, identity)
        save_background_authorization(student_id, openid_fingerprint(identity), token)

    return MiniProgramAuthResponse(
        status="ok",
        sessionId=session_id,
        studentName=student_name,
        studentId=student_id,
    )


def _wechat_error(code: str, message: str, response_status: int) -> HTTPException:
    return HTTPException(
        status_code=response_status,
        detail={"code": code, "message": message},
    )


def _exchange_or_raise(code: str) -> WechatIdentity:
    try:
        return exchange_code(code)
    except WechatNotConfiguredError as exc:
        raise _wechat_error("wechat_not_configured", str(exc), status.HTTP_503_SERVICE_UNAVAILABLE)
    except WechatIdentityError as exc:
        raise _wechat_error("wechat_login_failed", str(exc), status.HTTP_401_UNAUTHORIZED)


@router.post("/auth/wechat-login", response_model=MiniProgramAuthResponse)
@limiter.limit("10/minute")
def wechat_login(
    payload: WechatCodeRequest,
    request: Request,
) -> MiniProgramAuthResponse:
    """使用已绑定微信身份恢复对应学校账号的小程序会话。"""
    identity = _exchange_or_raise(payload.code)
    fingerprint = openid_fingerprint(identity)
    with get_sync_session_factory()() as db:
        binding = (
            db.query(WechatBinding)
            .filter(WechatBinding.openid_fingerprint == fingerprint)
            .first()
        )
        if binding is None:
            raise _wechat_error(
                "wechat_not_bound",
                "当前微信尚未绑定学校账号，请先使用学号密码登录并绑定",
                status.HTTP_409_CONFLICT,
            )
        student_id = binding.student_id

    with account_school_session_lock(student_id):
        # 绑定查找之后可能正在解绑，必须在恢复锁内重新确认。
        with get_sync_session_factory()() as db:
            binding = db.query(WechatBinding.id).filter_by(
                student_id=student_id, openid_fingerprint=fingerprint,
            ).first()
            if binding is None:
                raise _wechat_error("wechat_not_bound", "微信绑定已解除，请重新绑定", 409)
        try:
            client, ehall_client, shared = load_shared_school_clients(student_id)
            client.validate_session()
        except (SchoolSessionUnavailableError, AuthenticationError, ValueError) as exc:
            from app.school_session_service import mark_school_session_invalid

            mark_school_session_invalid(student_id)
            raise _wechat_error(
                "school_session_expired",
                "学校会话已过期，请使用学号密码重新登录；微信绑定仍保留",
                status.HTTP_428_PRECONDITION_REQUIRED,
            ) from exc
        session = request.app.state.sessions.create(
            client,
            student_name=shared.student_name or student_id,
            ehall_client=ehall_client,
            student_account=student_id,
            school_session_version=shared.version,
        )
        return MiniProgramAuthResponse(
            status="ok",
            sessionId=session.id,
            studentName=shared.student_name or student_id,
            studentId=student_id,
        )


@router.get("/auth/wechat-binding", response_model=WechatBindingStatus)
def get_wechat_binding(session: AppSession = Depends(require_session)) -> dict[str, bool]:
    student_id = student_id_of(session)
    with get_sync_session_factory()() as db:
        binding = db.query(WechatBinding).filter(WechatBinding.student_id == student_id).first()
        return {"isBound": binding is not None}


@router.post("/auth/wechat-binding", response_model=WechatBindingResponse)
@limiter.limit("10/minute")
def bind_wechat(
    payload: WechatCodeRequest,
    request: Request,
    session: AppSession = Depends(require_session),
) -> dict[str, str]:
    persist_wechat_binding(student_id_of(session), _exchange_or_raise(payload.code))
    return {"status": "ok"}


def persist_wechat_binding(student_id: str, identity: WechatIdentity) -> None:
    """提交共用的一对一微信绑定。"""
    with get_sync_session_factory()() as db:
        try:
            save_wechat_binding(db, student_id, identity)
            db.commit()
        except IntegrityError as exc:
            db.rollback()
            raise _wechat_error("wechat_binding_conflict", "微信绑定状态已被其他请求占用，请刷新后重试", 409) from exc


def save_wechat_binding(db: Session, student_id: str, identity: WechatIdentity) -> None:
    """在调用方事务内执行学校账号与微信身份的一对一绑定规则。"""
    if not student_id:
        raise HTTPException(status_code=401, detail="无法确认当前学号")
    fingerprint = openid_fingerprint(identity)
    encrypted_openid = encrypt_openid(identity.openid)
    student_binding = (
        db.query(WechatBinding).filter(WechatBinding.student_id == student_id).first()
    )
    openid_binding = (
        db.query(WechatBinding)
        .filter(WechatBinding.openid_fingerprint == fingerprint)
        .first()
    )
    if openid_binding is not None and openid_binding.student_id != student_id:
        raise _wechat_error(
            "wechat_already_bound",
            "当前微信已绑定其他学校账号，请先解除原绑定",
            status.HTTP_409_CONFLICT,
        )
    if student_binding is not None:
        if student_binding.openid_fingerprint != fingerprint:
            raise _wechat_error(
                "student_already_bound",
                "当前学校账号已绑定其他微信，请先解绑",
                status.HTTP_409_CONFLICT,
            )
        student_binding.encrypted_openid = encrypted_openid
        student_binding.app_id = identity.app_id
    else:
        db.add(
            WechatBinding(
                student_id=student_id,
                openid_fingerprint=fingerprint,
                encrypted_openid=encrypted_openid,
                app_id=identity.app_id,
            )
        )


@router.delete("/auth/wechat-binding", response_model=WechatBindingResponse)
def unbind_wechat(session: AppSession = Depends(require_session)) -> dict[str, str]:
    student_id = student_id_of(session)
    from app.routes.mini_notifications import revoke_mini_access
    with account_school_session_lock(student_id):
        revoke_mini_access(student_id)
        with get_sync_session_factory()() as db:
            binding = db.query(WechatBinding).filter(WechatBinding.student_id == student_id).first()
            if binding is None:
                raise _wechat_error("wechat_not_bound", "当前学校账号尚未绑定微信", status.HTTP_404_NOT_FOUND)
            db.delete(binding)
            db.commit()
        release_if_unused(student_id)
    return {"status": "ok"}
