"""账号调课 V2：课程实例、区间预览与依赖检测。"""

from datetime import date, timedelta

from app.schedule_adjustment_models import (
    AdjustmentMetadata,
    AdjustmentPair,
    AdjustmentPreview,
    AdjustmentRequest,
    PairPreview,
)
from app.widget_schedule import WidgetOccurrence, _segment


def intersects(item: WidgetOccurrence, day: date, first: int, last: int) -> bool:
    return item.occurrence_date == day and item.start_section <= last and first <= item.end_section


def apply_pair(
    items: list[WidgetOccurrence], pair: AdjustmentPair, monday: date
) -> list[WidgetOccurrence]:
    """两侧从同一快照计算；移动仅选择来源实例，交换则处理两侧整个区间。"""
    result: list[WidgetOccurrence] = []
    for item in items:
        source = intersects(item, pair.source_date, pair.source_start, pair.source_end)
        target = intersects(item, pair.target_date, pair.target_start, pair.target_end)
        if source and pair.action != "swap" and item.item_key not in pair.source_keys:
            source = False
        if not source and not target:
            result.append(item)
            continue
        if target and pair.action in ("move", "choose"):
            result.append(item)
            continue
        first = pair.source_start if source else pair.target_start
        last = pair.source_end if source else pair.target_end
        cut_start, cut_end = max(first, item.start_section), min(last, item.end_section)
        if item.start_section < cut_start:
            result.append(
                _segment(item, item.start_section, cut_start - 1, item.occurrence_date, monday)
            )
        if item.end_section > cut_end:
            result.append(
                _segment(item, cut_end + 1, item.end_section, item.occurrence_date, monday)
            )
        if source or pair.action == "swap":
            offset = (
                pair.target_start - pair.source_start
                if source
                else pair.source_start - pair.target_start
            )
            day = pair.target_date if source else pair.source_date
            result.append(_segment(item, cut_start + offset, cut_end + offset, day, monday))
    return sorted(result, key=lambda row: (row.occurrence_date, row.start_section, row.item_key))


def build_preview(
    items: list[WidgetOccurrence], request: AdjustmentRequest, fingerprint: str
) -> AdjustmentPreview:
    monday = request.first_week_start - timedelta(days=request.first_week_start.weekday())
    previews: list[PairPreview] = []
    affected_count = 0
    for pair in request.pairs:
        before = [
            item for item in items if item.occurrence_date in {pair.source_date, pair.target_date}
        ]
        selected = [
            item
            for item in before
            if item.item_key in pair.source_keys
            and intersects(item, pair.source_date, pair.source_start, pair.source_end)
        ]
        if request.operation == "course" and (
            len(selected) != len(pair.source_keys)
            or any(
                item.start_section > pair.source_start or item.end_section < pair.source_end
                for item in selected
            )
        ):
            raise ValueError("来源课程或节次已变化，请重新选择实际课程")
        affected = [
            item
            for item in before
            if (
                intersects(item, pair.source_date, pair.source_start, pair.source_end)
                and (
                    request.operation == "day"
                    or pair.action == "swap"
                    or item.item_key in pair.source_keys
                )
            )
            or intersects(item, pair.target_date, pair.target_start, pair.target_end)
        ]
        if not affected:
            raise ValueError("配对两侧均没有课程，请移除此配对")
        affected_count += len(affected)
        conflicts = [
            item
            for item in before
            if intersects(item, pair.target_date, pair.target_start, pair.target_end)
        ]
        if request.operation == "course" and conflicts and pair.action == "move":
            raise ValueError("目标存在冲突，请选择交换或覆盖")
        labels = [
            "请选择交换或覆盖，尚未确定调整结果"
            if pair.action == "choose" and conflicts
            else "交换两侧区间全部课程"
            if pair.action == "swap"
            else "覆盖移除目标冲突部分"
            if pair.action == "replace"
            else "移入目标日期"
        ]
        if any(
            (
                intersects(item, pair.source_date, pair.source_start, pair.source_end)
                and (item.start_section < pair.source_start or item.end_section > pair.source_end)
            )
            or (
                intersects(item, pair.target_date, pair.target_start, pair.target_end)
                and (item.start_section < pair.target_start or item.end_section > pair.target_end)
            )
            for item in affected
        ):
            labels.append("跨区间连堂课将拆分，区间外节次保留")
        if request.operation == "day" and not any(
            item.occurrence_date == pair.source_date for item in before
        ):
            labels.append("来源为空，目标当天课程将移到来源日期")
        elif request.operation == "day" and not conflicts:
            labels.append("目标为空，来源当天课程将移到目标日期")
        previews.append(
            PairPreview(
                pair=pair,
                before=before,
                after=before
                if pair.action == "choose" and conflicts
                else apply_pair(before, pair, monday),
                conflicts=conflicts,
                labels=labels,
            )
        )
    return AdjustmentPreview(
        fingerprint=fingerprint,
        ready=all(pair.pair.action != "choose" for pair in previews),
        pairs=previews,
        affectedCount=affected_count,
    )


def apply_metadata(
    items: list[WidgetOccurrence], metadata: AdjustmentMetadata, monday: date
) -> list[WidgetOccurrence]:
    result = items
    for pair in metadata.request.pairs:
        result = apply_pair(result, pair, monday)
    return result


def pair_dependencies(first: list[AdjustmentPair], second: list[AdjustmentPair]) -> bool:
    first_ranges = [(p.source_date, p.source_start, p.source_end) for p in first] + [
        (p.target_date, p.target_start, p.target_end) for p in first
    ]
    second_ranges = [(p.source_date, p.source_start, p.source_end) for p in second] + [
        (p.target_date, p.target_start, p.target_end) for p in second
    ]
    return any(
        day == other_day and start <= other_end and other_start <= end
        for day, start, end in first_ranges
        for other_day, other_start, other_end in second_ranges
    )
