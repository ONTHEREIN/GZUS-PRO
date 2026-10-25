"""微信绑定身份确认、独立订阅设置及服务端后台授权。"""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.database import (
    BackgroundNotificationProfile, MiniNotificationAccess, MiniNotificationDelivery, MiniNotificationPreference,
    MiniSubscriptionReceipt, WechatBinding, get_sync_session_factory,
)
from app.mini_notification_models import (
    MiniBackgroundAuthorization, MiniDeliveryResult, MiniNotificationConfig, MiniNotificationPreferenceRequest,
    MiniNotificationSetting, MiniSubscriptionRequest,
)
from app.rate_limit import limiter
from app.routes.auth import auto_login
from app.routes.deps import require_session
from app.routes.mini_program import _exchange_or_raise
from app.schemas import AutoLoginRequest
from app.sessions import (
    AppSession, credential_fingerprint, decrypt_credential_payload, student_id_of,
)
from app.wechat_identity import openid_fingerprint
from app.wechat_notifications import MINI_NOTIFICATION_LABELS, aware, template_ids

router = APIRouter(prefix="/mini/notifications", tags=["mini-program"])


def _verified_fingerprint(code: str, student_id: str) -> str:
    identity = _exchange_or_raise(code)
    fingerprint = openid_fingerprint(identity)
    with get_sync_session_factory()() as db:
        binding = db.query(WechatBinding).filter_by(student_id=student_id).first()
        if binding is None or binding.openid_fingerprint != fingerprint:
            raise HTTPException(status_code=403, detail="请先将当前微信绑定到当前学校账号")
    return fingerprint


def notification_config(student_id: str) -> MiniNotificationConfig:
    ids = template_ids()
    with get_sync_session_factory()() as db:
        binding = db.query(WechatBinding).filter_by(student_id=student_id).first()
        access = db.get(MiniNotificationAccess, student_id)
        profile = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        authorized = bool(binding is not None and access is not None and profile is not None
                          and access.openid_fingerprint == binding.openid_fingerprint)
        settings: list[MiniNotificationSetting] = []
        for kind, label in MINI_NOTIFICATION_LABELS.items():
            preference = db.get(MiniNotificationPreference, (binding.openid_fingerprint, kind)) if binding else None
            delivery = db.query(MiniNotificationDelivery).filter_by(
                openid_fingerprint=binding.openid_fingerprint, notification_type=kind,
            ).order_by(MiniNotificationDelivery.created_at.desc()).first() if binding else None
            settings.append(MiniNotificationSetting(
                type=kind, label=label, templateId=ids[kind] or None,
                enabled=bool(preference is not None and preference.enabled),
                credits=preference.credits if preference is not None else 0,
                subscriptionStatus=preference.subscription_status if preference else "not_subscribed",
                lastError=preference.last_error if preference else None,
                lastDelivery=MiniDeliveryResult(status=delivery.status,
                    attemptedAt=aware(delivery.created_at), error=delivery.error) if delivery else None,
            ))
        return MiniNotificationConfig(bound=binding is not None, backgroundAuthorized=authorized,
            backgroundSuspended=bool(authorized and profile.suspended_at is not None),
            lastCheckedAt=profile.last_checked_at if authorized else None,
            lastError=(profile.suspension_reason or access.course_sync_error or profile.last_error) if authorized else None,
            settings=settings)


@router.get("/config", response_model=MiniNotificationConfig)
def get_config(session: AppSession = Depends(require_session)) -> MiniNotificationConfig:
    return notification_config(student_id_of(session))


@router.put("/preference", response_model=MiniNotificationConfig)
def put_preference(payload: MiniNotificationPreferenceRequest,
                   session: AppSession = Depends(require_session)) -> MiniNotificationConfig:
    student_id = student_id_of(session)
    fingerprint = _verified_fingerprint(payload.code, student_id)
    now = datetime.now(timezone.utc)
    with get_sync_session_factory()() as db:
        row = db.get(MiniNotificationPreference, (fingerprint, payload.notification_type))
        if row is None:
            row = MiniNotificationPreference(openid_fingerprint=fingerprint,
                notification_type=payload.notification_type, student_id=student_id,
                enabled=payload.enabled, enabled_since=now, credits=0,
                subscription_status="not_subscribed", last_error=None)
            db.add(row)
        else:
            if payload.enabled and not row.enabled:
                row.enabled_since = now
            row.enabled = payload.enabled
        db.commit()
    return notification_config(student_id)


@router.post("/subscription", response_model=MiniNotificationConfig)
@limiter.limit("20/minute")
def register_subscription(payload: MiniSubscriptionRequest, request: Request,
                          session: AppSession = Depends(require_session)) -> MiniNotificationConfig:
    student_id = student_id_of(session)
    fingerprint = _verified_fingerprint(payload.code, student_id)
    if template_ids()[payload.notification_type] != payload.template_id:
        raise HTTPException(status_code=409, detail="订阅模板已变更，请刷新通知设置后重新订阅")
    with get_sync_session_factory()() as db:
        receipt = db.get(MiniSubscriptionReceipt, payload.request_id)
        if receipt is not None:
            if receipt.openid_fingerprint != fingerprint or receipt.notification_type != payload.notification_type:
                raise HTTPException(status_code=409, detail="订阅请求编号已被使用")
            return notification_config(student_id)
        row = db.get(MiniNotificationPreference, (fingerprint, payload.notification_type))
        if row is None:
            raise HTTPException(status_code=409, detail="请先开启该类提醒")
        db.add(MiniSubscriptionReceipt(request_id=payload.request_id, openid_fingerprint=fingerprint,
                    notification_type=payload.notification_type, created_at=datetime.now(timezone.utc)))
        # 在数据库当前值上递增，不能用读取时的次数覆盖并发订阅或发送扣减。
        values = {MiniNotificationPreference.subscription_status: payload.result,
                  MiniNotificationPreference.last_error: None}
        if payload.result == "accept":
            values[MiniNotificationPreference.credits] = MiniNotificationPreference.credits + 1
        elif payload.result in {"reject", "ban"}:
            values[MiniNotificationPreference.credits] = 0
        try:
            db.query(MiniNotificationPreference).filter_by(
                openid_fingerprint=fingerprint, notification_type=payload.notification_type,
            ).update(values, synchronize_session=False)
            db.commit()
        except IntegrityError:
            db.rollback()
            # 并发重复请求只登记一次；其他完整性错误不能当作成功。
            receipt = db.get(MiniSubscriptionReceipt, payload.request_id)
            if (receipt is None or receipt.openid_fingerprint != fingerprint
                    or receipt.notification_type != payload.notification_type):
                raise
    return notification_config(student_id)


@router.post("/background", response_model=MiniNotificationConfig)
@limiter.limit("5/minute")
def authorize_background(payload: MiniBackgroundAuthorization, request: Request,
                         session: AppSession = Depends(require_session)) -> MiniNotificationConfig:
    student_id = student_id_of(session)
    if payload.account != student_id:
        raise HTTPException(status_code=403, detail="后台授权学号必须与当前登录账号一致")
    fingerprint = _verified_fingerprint(payload.code, student_id)
    # 复用登录验证，只在服务端处理凭据，不把 credentialToken 下发给微信。
    result = auto_login(AutoLoginRequest.model_validate(payload.model_dump()), request)
    token = result.get("credentialToken")
    if not isinstance(token, str) or not token:
        raise HTTPException(status_code=502, detail="学校登录未生成有效的后台授权凭据")
    save_background_authorization(student_id, fingerprint, token)
    return notification_config(student_id)


def save_background_authorization(student_id: str, fingerprint: str, token: str) -> None:
    """复用已验证登录产生的加密凭据，不再次调用学校登录。"""
    account, _, device_id = decrypt_credential_payload(token, get_settings().credential_encryption_key)
    if account != student_id or device_id is None:
        raise HTTPException(status_code=502, detail="后台授权凭据账号或设备标识无效")
    from app.school_session_service import account_school_session_lock
    with account_school_session_lock(student_id), get_sync_session_factory()() as db:
        binding = db.query(WechatBinding).filter_by(student_id=student_id).first()
        if binding is None or binding.openid_fingerprint != fingerprint:
            raise HTTPException(status_code=409, detail="授权期间微信绑定已变更，请重新绑定")
        profile = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        if profile is None:
            profile = BackgroundNotificationProfile(student_id=student_id, mobile_enabled=False,
                    credential_fingerprint=credential_fingerprint(device_id), encrypted_credentials=token,
                    notices_enabled=False, grades_enabled=False, exams_enabled=False, attendance_enabled=False)
            db.add(profile)
        elif not profile.mobile_enabled:
            profile.credential_fingerprint = credential_fingerprint(device_id)
            profile.encrypted_credentials = token
        access = db.get(MiniNotificationAccess, student_id)
        if access is None:
            db.add(MiniNotificationAccess(student_id=student_id, openid_fingerprint=fingerprint,
                                         authorized_at=datetime.now(timezone.utc)))
        elif access.openid_fingerprint != fingerprint:
            raise HTTPException(status_code=409, detail="微信后台授权身份已变更，请先关闭旧授权")
        db.commit()


def revoke_mini_access(student_id: str) -> None:
    """只撤销微信订阅及独占检测授权，保留移动端后台设置。"""
    from app.school_session_service import account_school_session_lock, release_if_unused
    with account_school_session_lock(student_id), get_sync_session_factory()() as db:
        access = db.get(MiniNotificationAccess, student_id)
        if access is not None:
            db.delete(access)
        preferences = db.query(MiniNotificationPreference).filter_by(student_id=student_id).all()
        for row in preferences:
            row.enabled, row.credits, row.subscription_status = False, 0, "not_subscribed"
        profile = db.query(BackgroundNotificationProfile).filter_by(student_id=student_id).first()
        if profile is not None and not profile.mobile_enabled:
            db.delete(profile)
        db.commit()
    release_if_unused(student_id)


@router.delete("/background", response_model=MiniNotificationConfig)
def disable_background(session: AppSession = Depends(require_session)) -> MiniNotificationConfig:
    revoke_mini_access(student_id_of(session))
    return notification_config(student_id_of(session))
