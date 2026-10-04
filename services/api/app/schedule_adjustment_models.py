"""个人调课 V2 的严格协议模型，供 API 与生效课表引擎共用。"""

from datetime import date, timedelta
import hashlib
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator, computed_field


class WidgetOccurrence(BaseModel):
    item_key: str = Field(alias="itemKey")
    occurrence_date: date = Field(alias="date")
    week: int
    weekday: int
    start_section: int = Field(alias="startSection")
    end_section: int = Field(alias="endSection")
    time: str
    name: str
    classroom: str
    teacher: str
    ongoing: bool

    @computed_field(alias="groupId")
    @property
    def group_id(self) -> str:
        root = self.item_key.split("->", 1)[0]
        root = re.sub(r"(:\d+-\d+)+$", "", root)
        match = re.match(r"course:(\d{4}-\d{2}-\d{2}):(.*)", root)
        identity = f"{date.fromisoformat(match[1]).isoweekday()}:{match[2]}" if match else root
        return hashlib.sha256(identity.encode()).hexdigest()


class AdjustmentPair(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source_date: date = Field(alias="sourceDate")
    target_date: date = Field(alias="targetDate")
    source_start: int = Field(alias="sourceStart", ge=1, le=16)
    source_end: int = Field(alias="sourceEnd", ge=1, le=16)
    target_start: int = Field(alias="targetStart", ge=1, le=16)
    source_keys: list[str] = Field(alias="sourceKeys", max_length=500)
    action: Literal["move", "swap", "replace", "choose"]

    @property
    def target_end(self) -> int:
        return self.target_start + self.source_end - self.source_start

    @model_validator(mode="after")
    def valid_range(self) -> "AdjustmentPair":
        if self.source_end < self.source_start or self.target_end > 16:
            raise ValueError("节次区间无效或目标超过第16节")
        if (
            self.source_date == self.target_date
            and self.source_start <= self.target_end
            and self.target_start <= self.source_end
        ):
            raise ValueError("同日调课的来源与目标节次不能重叠")
        if len(self.source_keys) != len(set(self.source_keys)):
            raise ValueError("来源课程不能重复")
        return self


class AdjustmentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    schema_version: Literal[2] = Field(alias="schemaVersion")
    year: int = Field(ge=2000, le=3000)
    term: int = Field(ge=1, le=2)
    first_week_start: date = Field(alias="firstWeekStart")
    operation: Literal["course", "day"]
    pairs: list[AdjustmentPair] = Field(min_length=1, max_length=60)

    @model_validator(mode="after")
    def valid_pairs(self) -> "AdjustmentRequest":
        if not 2000 <= self.first_week_start.year <= 3000:
            raise ValueError("开学日期必须在 2000 至 3000 年之间")
        if self.first_week_start.weekday() != 0:
            raise ValueError("第一周开始日期必须是周一")
        seen: set[date] = set()
        for pair in self.pairs:
            dates = {pair.source_date, pair.target_date}
            if seen & dates:
                raise ValueError("不同配对不能复用日期，请分次调整")
            seen |= dates
            for day in dates:
                if not self.first_week_start <= day < self.first_week_start + timedelta(days=210):
                    raise ValueError("调课日期必须在当前学期30周范围内")
            if self.operation == "day" and (
                pair.source_date == pair.target_date
                or pair.source_start != 1
                or pair.source_end != 16
                or pair.target_start != 1
                or pair.action != "swap"
            ):
                raise ValueError("整日互换必须选择不同日期、1–16节和交换方式")
            if self.operation == "course" and not pair.source_keys:
                raise ValueError("按课程调课必须选择具体课程实例")
        return self


class AdjustmentCommit(AdjustmentRequest):
    client_id: str = Field(alias="clientId", min_length=1, max_length=100)
    fingerprint: str = Field(min_length=64, max_length=64)


class PairPreview(BaseModel):
    pair: AdjustmentPair
    before: list[WidgetOccurrence]
    after: list[WidgetOccurrence]
    conflicts: list[WidgetOccurrence]
    labels: list[str]


class AdjustmentPreview(BaseModel):
    fingerprint: str
    ready: bool
    pairs: list[PairPreview]
    affected_count: int = Field(alias="affectedCount")


class AdjustmentMetadata(BaseModel):
    request: AdjustmentRequest
    preview: AdjustmentPreview


class RestoreRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    year: int = Field(ge=2000, le=3000)
    term: int = Field(ge=1, le=2)
    first_week_start: date = Field(alias="firstWeekStart")
    expected_revision: int = Field(alias="expectedRevision", ge=1)
    fingerprint: str | None

    @model_validator(mode="after")
    def valid_first_week(self) -> "RestoreRequest":
        if not 2000 <= self.first_week_start.year <= 3000:
            raise ValueError("开学日期必须在 2000 至 3000 年之间")
        if self.first_week_start.weekday() != 0:
            raise ValueError("第一周开始日期必须是周一")
        return self


class RestorePreview(BaseModel):
    fingerprint: str
    blockers: list[str]
    before: list[WidgetOccurrence]
    after: list[WidgetOccurrence]
