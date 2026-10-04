"""小程序通知入口与微信响应的运行时校验模型。"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas import CredentialLoginRequest

MiniNotificationType = Literal[
    "exam_reminder", "grade_update", "course_reminder", "attendance_update", "ecard_reminder"
]


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


class MiniNotificationSetting(BaseModel):
    type: MiniNotificationType
    label: str
    template_id: str | None = Field(alias="templateId")
    enabled: bool
    credits: int
    subscription_status: str = Field(alias="subscriptionStatus")
    last_error: str | None = Field(alias="lastError")


class MiniNotificationConfig(BaseModel):
    bound: bool
    background_authorized: bool = Field(alias="backgroundAuthorized")
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
