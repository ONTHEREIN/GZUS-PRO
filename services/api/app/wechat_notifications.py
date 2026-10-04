"""微信一次性订阅连接器与独立事件投递账本。"""
from __future__ import annotations

import logging
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Final
from zoneinfo import ZoneInfo

import httpx
from cryptography.fernet import InvalidToken
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.config import get_settings
from app.database import (
    MiniNotificationAccess, MiniNotificationDelivery,
    MiniNotificationPreference, NotificationDelivery, WechatBinding, get_sync_session_factory,
)
from app.mini_notification_models import MiniNotificationType, WechatAccessToken, WechatApiResult
from app.sessions import _get_fernet

logger = logging.getLogger(__name__)
MINI_NOTIFICATION_LABELS: Final[dict[MiniNotificationType, str]] = {
    "exam_reminder": "考试", "grade_update": "成绩", "course_reminder": "课程",
    "attendance_update": "考勤", "ecard_reminder": "缴费",
}


class SubscribePayloadError(ValueError):
    """事件缺少微信模板要求的业务字段，不能编造内容发送。"""


class WechatPushError(RuntimeError):
    """微信返回明确的拒绝响应。"""


class MiniUtilityMetric(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    label: str
    value: str


class MiniEventExtras(BaseModel):
    model_config = ConfigDict(extra="ignore")
    course_name: str | None = Field(default=None, alias="courseName")
    location: str | None = None
    exam_time: str | None = Field(default=None, alias="examTime")
    course_time: str | None = Field(default=None, alias="courseTime")
    score: str | None = None
    item_key: str | None = Field(default=None, alias="itemKey")
    utility_metrics: list[MiniUtilityMetric] = Field(default_factory=list, alias="utilityMetrics")


def template_ids() -> dict[MiniNotificationType, str]:
    settings = get_settings()
    return {
        "exam_reminder": settings.wechat_exam_template_id,
        "grade_update": settings.wechat_grade_template_id,
        "course_reminder": settings.wechat_course_template_id,
        "attendance_update": settings.wechat_attendance_template_id,
        "ecard_reminder": settings.wechat_ecard_template_id,
    }


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def mini_type_enabled(student_id: str, notification_type: str) -> bool:
    with get_sync_session_factory()() as db:
        access = db.get(MiniNotificationAccess, student_id)
        if access is None:
            return False
        row = db.get(MiniNotificationPreference, (access.openid_fingerprint, notification_type))
        return bool(row is not None and row.enabled)


def _required(value: str | None, label: str) -> str:
    if value is None or not value.strip():
        raise SubscribePayloadError(f"微信提醒缺少{label}")
    return value.strip()


def _thing(value: str) -> dict[str, str]:
    if not value.strip():
        raise SubscribePayloadError("微信模板文本不能为空")
    return {"value": value[:20]}


def subscription_data(event: NotificationDelivery) -> dict[str, dict[str, str]]:
    """字段编号与选用模板一致；不把未知时间、非数字用量伪造成有效数据。"""
    extras = MiniEventExtras.model_validate_json(event.extras_json or "{}")
    timestamp = aware(event.created_at).astimezone(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M")
    if event.notification_type == "course_reminder":
        return {"thing5": _thing(_required(extras.course_name, "课程名称")),
                "time3": {"value": _required(extras.course_time, "上课时间")},
                "thing2": _thing(_required(extras.location, "上课地点"))}
    if event.notification_type == "exam_reminder":
        return {"thing7": _thing(_required(extras.course_name, "考试科目")),
                "time4": {"value": _required(extras.exam_time, "考试时间")},
                "thing5": _thing(_required(extras.location, "考试地点")),
                "thing6": _thing(event.body or "")}
    if event.notification_type == "grade_update":
        # 待审批模板的选用顺序固定为课程名称、成绩文本、发布时间。
        return {"thing1": _thing(_required(extras.course_name, "课程名称")),
                "thing2": _thing(_required(extras.score, "成绩文本")), "time3": {"value": timestamp}}
    if event.notification_type == "attendance_update":
        # 聚合异常未必发生在今天，使用真实提醒时间而非伪造异常日期。
        return {"thing7": _thing(event.body or ""), "thing4": _thing("请到考勤页核对点名记录"),
                "time8": {"value": timestamp}}
    if event.notification_type == "ecard_reminder":
        names = {"power": "电费", "cold_water": "冷水", "hot_water": "热水"}
        label = names.get(extras.item_key or "")
        if label is None:
            raise SubscribePayloadError("每日水电汇总保留在消息中心，不套用余额不足模板")
        metric = next((item for item in extras.utility_metrics if item.label == label), None)
        if metric is None:
            raise SubscribePayloadError("水电提醒缺少余额指标")
        raw = metric.value.split()[0] if metric.value.strip() else ""
        import re
        match = re.fullmatch(r"(-?\d+(?:\.\d+)?)(?:度|吨|元)?", raw)
        if match is None:
            raise SubscribePayloadError("水电剩余用量不是数字")
        try:
            amount = Decimal(match.group(1))
        except InvalidOperation as exc:
            raise SubscribePayloadError("水电剩余用量无效") from exc
        return {"thing2": _thing(label), "number6": {"value": str(amount)},
                "thing4": _thing(event.body or ""), "time10": {"value": timestamp}}
    raise SubscribePayloadError(f"不支持的微信提醒类型：{event.notification_type}")


class WechatSubscribeClient:
    """微信外部接口；token 获取可重试，发送超时不能安全重试。"""

    def token(self) -> str:
        settings = get_settings()
        if not settings.wechat_miniprogram_app_id or not settings.wechat_miniprogram_app_secret:
            raise WechatPushError("微信 AppID/AppSecret 未配置")
        for attempt in range(1, 4):
            try:
                with httpx.Client(timeout=settings.request_timeout_seconds) as client:
                    response = client.post("https://api.weixin.qq.com/cgi-bin/stable_token", json={
                        "grant_type": "client_credential", "appid": settings.wechat_miniprogram_app_id,
                        "secret": settings.wechat_miniprogram_app_secret, "force_refresh": False,
                    })
                if response.status_code != 200:
                    raise WechatPushError(f"微信 token 获取失败，HTTP {response.status_code}")
                payload = response.json()
                if "errcode" in payload and payload["errcode"] != 0:
                    raise WechatPushError(f"微信 token 获取失败，错误码 {payload['errcode']}")
                return WechatAccessToken.model_validate(payload).access_token
            except (httpx.HTTPError, ValidationError, ValueError, WechatPushError):
                logger.warning("wechat_token_request_failed", extra={"attempt": attempt})
                if attempt == 3:
                    raise
                time.sleep(0.3 * attempt)
        raise WechatPushError("微信 token 获取未执行")

    def send(self, token: str, openid: str, template_id: str, page: str,
             data: dict[str, dict[str, str]]) -> WechatApiResult:
        with httpx.Client(timeout=get_settings().request_timeout_seconds) as client:
            response = client.post("https://api.weixin.qq.com/cgi-bin/message/subscribe/send",
                                   params={"access_token": token}, json={
                                       "touser": openid, "template_id": template_id, "page": page,
                                       "miniprogram_state": get_settings().wechat_notification_environment, "lang": "zh_CN", "data": data,
                                   })
        if response.status_code != 200:
            raise WechatPushError(f"微信发送结果未知，HTTP {response.status_code}")
        result = WechatApiResult.model_validate(response.json())
        return result.model_copy(update={"errmsg": result.errmsg.replace(openid, "[hidden]")})


def deliver_mini_event(event_id: int) -> None:
    """先原子占用次数与事件，再发一次；失败仅按明确响应恢复授权。"""
    now = datetime.now(timezone.utc)
    ids = template_ids()
    with get_sync_session_factory()() as db:
        event = db.get(NotificationDelivery, event_id)
        if event is None or event.notification_type not in ids:
            return
        access = db.get(MiniNotificationAccess, event.student_id)
        binding = db.query(WechatBinding).filter_by(student_id=event.student_id).first()
        if access is None or binding is None or access.openid_fingerprint != binding.openid_fingerprint:
            return
        preference = db.get(MiniNotificationPreference, (binding.openid_fingerprint, event.notification_type))
        if preference is None or not preference.enabled:
            return
        if event.delivery_expires_at is None or aware(event.delivery_expires_at) <= now:
            return
        if aware(event.created_at) < max(aware(access.authorized_at), aware(preference.enabled_since)):
            return
        fingerprint = binding.openid_fingerprint
        event_key = event.event_key
        if db.get(MiniNotificationDelivery, (fingerprint, event_key)) is not None:
            return
        template_id = ids[event.notification_type]
        state = "sending"
        error: str | None = None
        data: dict[str, dict[str, str]] = {}
        if not template_id:
            state, error = "unconfigured", "订阅模板待配置"
        elif preference.credits <= 0:
            state, error = "no_subscription", "订阅次数耗尽，请重新订阅"
        elif event.notification_type == "course_reminder" and not event_key.startswith("course:start:"):
            state, error = "unsupported", "下课提醒仅保留在消息中心"
        else:
            try:
                data = subscription_data(event)
            except (SubscribePayloadError, ValidationError, ValueError) as exc:
                state, error = "invalid", str(exc)[:200]
        deadline = aware(event.delivery_expires_at)
        if state == "sending" and event.notification_type in {"course_reminder", "exam_reminder"}:
            try:
                extras = MiniEventExtras.model_validate_json(event.extras_json or "{}")
                if event.notification_type == "course_reminder":
                    business_start = datetime.fromisoformat(_required(extras.course_time, "上课时间"))
                    if business_start.tzinfo is None:
                        business_start = business_start.replace(tzinfo=ZoneInfo("Asia/Shanghai"))
                else:
                    from app.cloud_notifications import _exam_start
                    business_start = _exam_start(_required(extras.exam_time, "考试时间"))
                    if business_start is None:
                        raise SubscribePayloadError("考试时间格式无效，无法确认提醒时效")
                deadline = min(deadline, business_start)
            except (ValueError, ValidationError) as exc:
                state, error = "invalid", str(exc)[:200]
        if state == "sending" and deadline <= now:
            return
        # token 和 OpenID 在消耗授权前准备，失败不会消耗用户次数。
        if state == "sending":
            db.commit()  # token 网络请求期间释放数据库连接。
            try:
                token = WechatSubscribeClient().token()
                openid = _get_fernet(get_settings().credential_encryption_key).decrypt(
                    binding.encrypted_openid.encode("ascii")).decode("utf-8")
            except (httpx.HTTPError, WechatPushError, ValidationError, ValueError, InvalidToken):
                preference.last_error = "微信投递准备失败，稍后在提醒有效期内重试"
                db.commit()
                logger.warning("wechat_delivery_prepare_failed", extra={"event_id": event_id})
                return
        if state == "sending":
            # 网络请求后重新确认授权，解绑或重新授权期间不能占用旧事件次数。
            current_access = db.get(MiniNotificationAccess, event.student_id, populate_existing=True)
            current_binding = db.query(WechatBinding).filter_by(student_id=event.student_id).populate_existing().first()
            preference = db.get(MiniNotificationPreference, (fingerprint, event.notification_type), populate_existing=True)
            if (current_access is None or current_binding is None or preference is None
                    or current_access.openid_fingerprint != fingerprint
                    or current_binding.openid_fingerprint != fingerprint or not preference.enabled
                    or aware(event.created_at) < max(aware(current_access.authorized_at), aware(preference.enabled_since))
                    or deadline <= datetime.now(timezone.utc)):
                return
        ledger = MiniNotificationDelivery(openid_fingerprint=fingerprint, event_key=event_key,
                    template_id=template_id, notification_type=event.notification_type,
                    status=state, error=error, created_at=now)
        db.add(ledger)
        try:
            db.flush()
            if state == "sending":
                claimed = db.query(MiniNotificationPreference).filter_by(
                    openid_fingerprint=fingerprint, notification_type=event.notification_type,
                    enabled=True).filter(MiniNotificationPreference.credits > 0).update(
                        {MiniNotificationPreference.credits: MiniNotificationPreference.credits - 1},
                        synchronize_session=False)
                if claimed != 1:
                    ledger.status, ledger.error = "no_subscription", "订阅次数耗尽"
                    db.commit()
                    return
            preference.last_error = error
            page = {"exam_reminder": "exams", "grade_update": "grades", "course_reminder": "schedule",
                    "attendance_update": "attendance", "ecard_reminder": "ecard"}[event.notification_type]
            notification_type = event.notification_type
            db.commit()
        except IntegrityError:
            db.rollback()
            return  # 并发调度已由唯一事件键占用。
    if state != "sending":
        return
    result: WechatApiResult | None = None
    try:
        result = WechatSubscribeClient().send(token, openid, template_id, f"pages/{page}/index", data)
        error = None if result.errcode == 0 else f"微信拒绝发送：{result.errcode} {result.errmsg}"
        state = "sent" if result.errcode == 0 else "failed"
    except (httpx.HTTPError, WechatPushError, ValidationError, ValueError):
        state, error = "unknown", "微信发送结果未知，为防重复通知不自动重发，请核对微信消息"
        logger.warning("wechat_delivery_result_unknown", extra={"event_id": event_id})
    with get_sync_session_factory()() as db:
        ledger = db.get(MiniNotificationDelivery, (fingerprint, event_key))
        if ledger is None:
            raise RuntimeError("微信投递账本丢失")
        ledger.status, ledger.error = state, error
        preference = db.get(MiniNotificationPreference, (fingerprint, notification_type))
        if preference is not None:
            preference.last_error = error
            if result is not None and result.errcode == 43101:
                preference.credits, preference.subscription_status = 0, "reject"
            elif result is not None and result.errcode != 0:
                preference.credits += 1
        db.commit()
    if error:
        logger.warning("wechat_delivery_failed", extra={"event_id": event_id, "state": state,
                                                       "errcode": result.errcode if result else None})


def run_mini_notification_dispatch_once() -> int:
    now = datetime.now(timezone.utc)
    with get_sync_session_factory()() as db:
        ids = [row.id for row in db.query(NotificationDelivery).filter(
            NotificationDelivery.delivery_expires_at > now,
            NotificationDelivery.title.is_not(None),
            NotificationDelivery.notification_type.in_(tuple(MINI_NOTIFICATION_LABELS)),
        ).order_by(NotificationDelivery.created_at).all()]
    for event_id in ids:
        deliver_mini_event(event_id)
    return len(ids)


async def run_mini_notification_dispatcher() -> None:
    import asyncio
    while True:
        try:
            await asyncio.to_thread(run_mini_notification_dispatch_once)
        except (httpx.HTTPError, ValueError, RuntimeError, SQLAlchemyError) as exc:
            # 数据库异常可能附带敏感 SQL 参数，只记录错误类型。
            logger.error("mini_notification_dispatch_failed", extra={"error_type": type(exc).__name__})
        await asyncio.sleep(30)
