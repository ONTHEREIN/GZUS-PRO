"""桌面组件生效课表协议：与 Flutter 的周次、覆盖及日期调课顺序一致。"""

from datetime import date, timedelta
import re
from typing import Literal

from pydantic import BaseModel, Field, JsonValue, model_validator

from app.leave_service import SECTION_TIMES
from app.schemas import ScheduleAdjustmentPayload, ScheduleAdjustmentResponse


class WidgetCourse(BaseModel):
    name: str = Field(min_length=1)
    weekday: int | None = Field(default=None, ge=1, le=7)
    start_section: int | None = Field(default=None, alias="startSection", ge=1, le=16)
    end_section: int | None = Field(default=None, alias="endSection", ge=1, le=16)
    teacher: str | None = None
    classroom: str | None = None
    weeks: str | None = None
    raw: dict[str, JsonValue] = Field(default_factory=dict)

    @model_validator(mode="after")
    def valid_sections(self) -> "WidgetCourse":
        if (
            self.start_section is not None
            and self.end_section is not None
            and self.end_section < self.start_section
        ):
            raise ValueError("结束节次不能早于开始节次")
        return self


class WidgetOverride(BaseModel):
    id: str = Field(min_length=1)
    match_key: str | None = Field(default=None, alias="matchKey")
    match_weekday: int | None = Field(default=None, alias="matchWeekday", ge=1, le=7)
    match_start_section: int | None = Field(default=None, alias="matchStartSection", ge=1, le=16)
    weeks: str | None = None
    hidden: bool
    course: WidgetCourse | None = None

    @model_validator(mode="after")
    def valid_course(self) -> "WidgetOverride":
        if not self.hidden and self.course is None:
            raise ValueError("新增或替换课程缺少课程资料")
        return self


class WidgetPendingAdjustment(ScheduleAdjustmentPayload):
    status: Literal["active", "restored", "archived"]
    revision: int = Field(ge=1)
    id: int | None = None

    @model_validator(mode="after")
    def valid_dates(self) -> "WidgetPendingAdjustment":
        source = date.fromisoformat(self.source_date)
        target = date.fromisoformat(self.target_date)
        if source == target:
            raise ValueError("调课源日期和目标日期必须不同")
        return self


class WidgetSnapshotRequest(BaseModel):
    year: int = Field(ge=2000, le=3000)
    term: int = Field(ge=1, le=2)
    first_week_start: date = Field(alias="firstWeekStart")
    overrides: list[WidgetOverride] = Field(max_length=500)
    pending_adjustments: list[WidgetPendingAdjustment] = Field(
        alias="pendingAdjustments", max_length=500
    )

    @model_validator(mode="after")
    def valid_scope(self) -> "WidgetSnapshotRequest":
        if not 2000 <= self.first_week_start.year <= 3000:
            raise ValueError("开学日期必须在 2000 至 3000 年之间")
        if any(
            item.year != self.year or item.term != self.term for item in self.pending_adjustments
        ):
            raise ValueError("待同步调课必须属于请求的学年学期")
        ids = [item.client_id for item in self.pending_adjustments]
        if len(ids) != len(set(ids)):
            raise ValueError("待同步调课编号不能重复")
        return self


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


def _week_contains(spec: str | None, week: int) -> bool:
    normalized = (spec or "").translate(
        str.maketrans({"（": "(", "）": ")", "，": ",", "；": ";", "、": ","})
    )
    found_number = False
    for segment in re.split(r"[,;]", normalized):
        if re.search(r"\d", segment):
            found_number = True
        if ("单" in segment and week % 2 == 0) or ("双" in segment and week % 2 != 0):
            continue
        ranges = re.findall(r"(\d+)\s*-\s*(\d+)", segment)
        if ranges:
            if any(int(start) <= week <= int(end) for start, end in ranges):
                return True
        elif any(int(value) == week for value in re.findall(r"\d+", segment)):
            return True
    return not found_number


def _matches(rule: WidgetOverride, course: WidgetCourse) -> bool:
    key = rule.match_key
    if key is None:
        return False
    if key.startswith("kch:"):
        matches = str(course.raw.get("kch", "")) == key[4:]
    elif key.startswith("name:"):
        matches = course.name == key[5:]
    else:
        return False
    return (
        matches
        and (rule.match_weekday is None or rule.match_weekday == course.weekday)
        and (rule.match_start_section is None or rule.match_start_section == course.start_section)
    )


def _normalize(
    courses: list[WidgetCourse], overrides: list[WidgetOverride]
) -> list[tuple[WidgetCourse, bool]]:
    result: list[tuple[WidgetCourse, bool]] = []
    for course in courses:
        rule = next((item for item in overrides if _matches(item, course)), None)
        if rule is None or (rule.hidden and (rule.weeks or "").strip()):
            result.append((course, False))
        elif not rule.hidden and rule.course is not None:
            result.append((rule.course, True))
    for rule in overrides:
        if rule.match_key is None and not rule.hidden and rule.course is not None:
            course = rule.course
            if not any(
                local
                and item.name == course.name
                and item.weekday == course.weekday
                and item.start_section == course.start_section
                for item, local in result
            ):
                result.append((course, True))
    return result


def _occurrence(course: WidgetCourse, day: date, week: int, key: str) -> WidgetOccurrence:
    start = course.start_section
    if start is None or course.weekday is None:
        raise ValueError("组件课程缺少开始节次或星期")
    end = course.end_section if course.end_section is not None else start
    return WidgetOccurrence(
        itemKey=key,
        date=day,
        week=week,
        weekday=day.isoweekday(),
        startSection=start,
        endSection=end,
        time=f"{SECTION_TIMES[start - 1][0]:%H:%M}-{SECTION_TIMES[end - 1][1]:%H:%M}",
        name=course.name,
        classroom=course.classroom or "",
        teacher=course.teacher or "",
        ongoing=False,
    )


def effective_widget_schedule(
    courses: list[WidgetCourse],
    request: WidgetSnapshotRequest,
    remote: list[ScheduleAdjustmentResponse],
) -> list[WidgetOccurrence]:
    """仅待同步操作覆盖云端同编号记录；已同步记录始终读取最新云端版本。"""
    monday = request.first_week_start - timedelta(days=request.first_week_start.weekday())
    result: list[WidgetOccurrence] = []
    for course, local in _normalize(courses, request.overrides):
        if course.weekday is None or course.start_section is None:
            continue  # 无具体时间的学校条目不会产生课程实例，与 Flutter 一致。
        for week in range(1, 31):
            if not _week_contains(course.weeks, week):
                continue
            if not local and any(
                rule.hidden and _matches(rule, course) and _week_contains(rule.weeks, week)
                for rule in request.overrides
            ):
                continue
            day = monday + timedelta(days=(week - 1) * 7 + course.weekday - 1)
            identity = next(
                (
                    course.raw[key]
                    for key in ("courseId", "kch_id", "kch")
                    if course.raw.get(key) is not None
                ),
                course.name,
            )
            key = f"course:{day.isoformat()}:{identity}:{course.start_section}:{course.end_section if course.end_section is not None else 'null'}:{course.teacher or ''}:{course.classroom or ''}"
            result.append(_occurrence(course, day, week, key))
    pending = {item.client_id: item for item in request.pending_adjustments}
    remote_ids = {item.client_id for item in remote}
    # 原生上下文可能在上传确认后尚未刷新；已确认或更新的云端修订不能被旧队列覆盖。
    adjustments: list[ScheduleAdjustmentResponse | WidgetPendingAdjustment] = [
        pending[item.client_id]
        if item.client_id in pending and pending[item.client_id].revision > item.revision
        else item
        for item in remote
    ]
    adjustments.extend(
        item for item in request.pending_adjustments if item.client_id not in remote_ids
    )
    for adjustment in adjustments:
        if adjustment.status != "active":
            continue
        source = date.fromisoformat(adjustment.source_date)
        target = date.fromisoformat(adjustment.target_date)
        moved = [
            item
            for item in result
            if item.occurrence_date == source
            and (
                not adjustment.source_occurrence_keys
                or item.item_key in adjustment.source_occurrence_keys
            )
        ]
        if not moved:
            continue
        result = [item for item in result if item not in moved]
        target_monday = target - timedelta(days=target.weekday())
        target_week = (target_monday - monday).days // 7 + 1
        for item in moved:
            if adjustment.conflict_mode == "replaceConflicts":
                result = [
                    candidate
                    for candidate in result
                    if not (
                        candidate.occurrence_date == target
                        and (
                            candidate.item_key in adjustment.target_conflict_keys
                            if adjustment.target_conflict_keys
                            else candidate.start_section <= item.end_section
                            and item.start_section <= candidate.end_section
                        )
                    )
                ]
            result.append(
                item.model_copy(
                    update={
                        "occurrence_date": target,
                        "week": target_week,
                        "weekday": target.isoweekday(),
                        "item_key": f"{item.item_key}->{target.isoformat()}",
                    }
                )
            )
    return sorted(result, key=lambda item: (item.occurrence_date, item.start_section))
