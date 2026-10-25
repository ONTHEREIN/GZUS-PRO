"""小程序通知入口与微信响应的运行时校验模型。"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas import AutoLoginRequest, CredentialLoginRequest

MiniNotificationType = Literal[
    "exam_reminder", "grade_update", "course_reminder", "attendance_update", "ecard_reminder"
]


class MiniProgramLoginRequest(AutoLoginRequest):
    """登录时可明确授权微信绑定与服务端后台检测，旧客户端不授权。"""

    background_consent: bool = Field(default=False, alias="backgroundConsent", strict=True)
    code: str | None = Field(default=None, min_length=1, max_length=512)


class MiniNotificationPreferenceRequest(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    notification_type: MiniNotificationType = Field(alias="type")
    enabled: bool
    code: str = Field(min_length=1, max_length=512)


class MiniSubscriptionRequest(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    notification_type: MiniNotificationType = Field(alias="type")
    template_id: str = Field(alias="templateId", min_length=1, max_length=200)
    request_id: str = Field(alias="requestId", min_length=16, max_length=64)
    result: Literal["accept", "reject", "ban", "filter"]
    code: str = Field(min_length=1, max_length=512)


class MiniBackgroundAuthorization(CredentialLoginRequest):
    model_config = ConfigDict(extra="ignore", strict=True)
    code: str = Field(min_length=1, max_length=512)
    consent: Literal[True]


class MiniDeliveryResult(BaseModel):
    """sent 仅表示微信接口接受，手机收件需另行验收。"""

    status: Literal["sending", "sent", "failed", "unknown", "unconfigured",
                    "no_subscription", "unsupported", "invalid"]
    attempted_at: datetime = Field(alias="attemptedAt")
    error: str | None


class MiniNotificationSetting(BaseModel):
    type: MiniNotificationType
    label: str
    template_id: str | None = Field(alias="templateId")
    enabled: bool
    credits: int
    subscription_status: str = Field(alias="subscriptionStatus")
    last_error: str | None = Field(alias="lastError")
    last_delivery: MiniDeliveryResult | None = Field(alias="lastDelivery")


class MiniNotificationConfig(BaseModel):
    bound: bool
    background_authorized: bool = Field(alias="backgroundAuthorized")
    background_suspended: bool = Field(alias="backgroundSuspended")
    last_checked_at: datetime | None = Field(alias="lastCheckedAt")
    last_error: str | None = Field(alias="lastError")
    settings: list[MiniNotificationSetting]


class WechatApiResult(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    errcode: int
    errmsg: str


class WechatAccessToken(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)
    access_token: str = Field(min_length=1)
    expires_in: int = Field(gt=0)
