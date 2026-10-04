"""批量调课：所有调整读取同一快照，按课程节次合并互不干扰的改动。"""
from datetime import date, timedelta
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.schedule_adjustment_models import AdjustmentPair, PairPreview, WidgetOccurrence


class BatchPair(AdjustmentPair):
    item_id: str = Field(alias="itemId", min_length=1, max_length=2000)


class BatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    schema_version: Literal[3] = Field(alias="schemaVersion")
    year: int = Field(ge=2000, le=3000)
    term: int = Field(ge=1, le=2)
    first_week_start: date = Field(alias="firstWeekStart")
    operation: Literal["course", "day", "dayCover", "partialDay"]
    pairs: list[BatchPair] = Field(min_length=1, max_length=60)

    @model_validator(mode="after")
    def valid_scope(self) -> "BatchRequest":
        if not 2000 <= self.first_week_start.year <= 3000 or self.first_week_start.weekday() != 0:
            raise ValueError("开学日期必须是2000至3000年之间的周一")
        if len({p.item_id for p in self.pairs}) != len(self.pairs):
            raise ValueError("调整项编号不能重复")
        used: set[date] = set()
        for p in self.pairs:
            dates = {p.source_date, p.target_date}
            if any(not self.first_week_start <= d < self.first_week_start + timedelta(days=210) for d in dates):
                raise ValueError("调课日期必须在当前学期30周内")
            if self.operation in {"day", "dayCover"}:
                expected_action = "swap" if self.operation == "day" else "replace"
                if used & dates or p.source_date == p.target_date or (p.source_start, p.source_end, p.target_start, p.action) != (1, 16, 1, expected_action):
                    raise ValueError("整日调整必须使用不重复的日期和完整课表区间")
                if self.operation == "dayCover" and not p.source_keys:
                    raise ValueError("整日覆盖必须选择来源日期的课程")
                used |= dates
            elif not p.source_keys:
                raise ValueError("必须选择具体课程实例")
        return self


class BatchCommit(BatchRequest):
    client_id: str = Field(alias="clientId", min_length=1, max_length=100)
    fingerprint: str = Field(min_length=64, max_length=64)


class BatchConflict(BaseModel):
    item_ids: list[str] = Field(alias="itemIds")
    message: str
    courses: list[WidgetOccurrence]


class BatchPairPreview(PairPreview):
    pair: BatchPair


class BatchPreview(BaseModel):
    fingerprint: str
    ready: bool
    pairs: list[BatchPairPreview]
    affected_count: int = Field(alias="affectedCount")
    batch_conflicts: list[BatchConflict] = Field(alias="batchConflicts")
    before: list[WidgetOccurrence]
    after: list[WidgetOccurrence]


class BatchMetadata(BaseModel):
    request: BatchRequest
    preview: BatchPreview

