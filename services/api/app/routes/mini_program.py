"""微信小程序专用入口。

小程序首期只提供短期应用会话：学校账号密码在服务端完成认证，客户端只保存
会话 ID。这里刻意不复用移动端登录响应，避免教务 Cookie、办事大厅 Token 与
长期凭据落入小程序本地存储。
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.exc import IntegrityError

from app.database import WechatBinding, get_sync_session_factory
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
from app.school_session_service import SchoolSessionUnavailableError, load_shared_school_clients
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
def login(payload: AutoLoginRequest, request: Request) -> MiniProgramAuthResponse:
    """使用现有学校认证链路创建小程序短期会话。"""
    result = auto_login(payload, request)

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

    try:
        client, ehall_client, shared = load_shared_school_clients(student_id)
    except (SchoolSessionUnavailableError, AuthenticationError, ValueError) as exc:
        raise _wechat_error(
            "school_session_expired",
            "学校会话已过期，请使用学号密码登录刷新",
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
    student_id = student_id_of(session)
    if not student_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="无法确认当前学号")
    identity = _exchange_or_raise(payload.code)
    fingerprint = openid_fingerprint(identity)
    encrypted_openid = encrypt_openid(identity.openid)
    with get_sync_session_factory()() as db:
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
        try:
            db.commit()
        except IntegrityError as exc:
            db.rollback()
            raise _wechat_error(
                "wechat_binding_conflict",
                "微信绑定状态已被其他请求占用，请刷新后重试",
                status.HTTP_409_CONFLICT,
            ) from exc
    return {"status": "ok"}


@router.delete("/auth/wechat-binding", response_model=WechatBindingResponse)
def unbind_wechat(session: AppSession = Depends(require_session)) -> dict[str, str]:
    student_id = student_id_of(session)
    with get_sync_session_factory()() as db:
        binding = db.query(WechatBinding).filter(WechatBinding.student_id == student_id).first()
        if binding is None:
            raise _wechat_error("wechat_not_bound", "当前学校账号尚未绑定微信", status.HTTP_404_NOT_FOUND)
        db.delete(binding)
        db.commit()
    return {"status": "ok"}
