"""同一快照上的批量调课计算。"""
from datetime import date
from itertools import combinations

from app.schedule_adjustment_models import AdjustmentPair, WidgetOccurrence
from app.schedule_adjustment_batch_models import BatchPair, BatchRequest, BatchConflict, BatchPairPreview, BatchPreview
from app.schedule_adjustment_v2 import intersects
from app.widget_schedule import _segment


def touched_sections(items: list[WidgetOccurrence], pair: BatchPair) -> set[tuple[str, int]]:
    return {
        (o.item_key, section)
        for o in items
        for section in range(o.start_section, o.end_section + 1)
        if (o.occurrence_date == pair.source_date and pair.source_start <= section <= pair.source_end and (pair.action == "swap" or o.item_key in pair.source_keys))
        or (o.occurrence_date == pair.target_date and pair.target_start <= section <= pair.target_end and pair.action in {"swap", "replace"})
    }


def batch_conflicts(items: list[WidgetOccurrence], pairs: list[BatchPair]) -> list[BatchConflict]:
    conflicts: list[BatchConflict] = []
    for a, b in combinations(pairs, 2):
        message = ""
        if a.target_date == b.target_date and a.target_start <= b.target_end and b.target_start <= a.target_end:
            message = "目标区间彼此重叠，请修改目标时间"
        elif (a.target_date == b.source_date and a.target_start <= b.source_end and b.source_start <= a.target_end) or (b.target_date == a.source_date and b.target_start <= a.source_end and a.source_start <= b.target_end):
            message = "目标落入另一项来源区间，请分开调整"
        elif touched_sections(items, a) & touched_sections(items, b):
            message = "重复选择或交换、覆盖会再次影响另一项课程，请修改选择"
        if message:
            keys = set(a.source_keys + b.source_keys) | {key for p in (a, b) for key, _ in touched_sections(items, p)}
            conflicts.append(BatchConflict(itemIds=[a.item_id, b.item_id], message=message, courses=[o for o in items if o.item_key in keys]))
    return conflicts


def apply_batch(items: list[WidgetOccurrence], pairs: list[BatchPair], monday: date) -> list[WidgetOccurrence]:
    """按原实例的连续保留区间重建，避免第二项读取第一项的拆分结果。"""
    if batch_conflicts(items, pairs):
        raise ValueError("批量调整互相干扰，不能重放")
    touched = set().union(*(touched_sections(items, p) for p in pairs))
    result: list[WidgetOccurrence] = []
    for o in items:
        remaining = [s for s in range(o.start_section, o.end_section + 1) if (o.item_key, s) not in touched]
        if len(remaining) == o.end_section - o.start_section + 1:
            result.append(o)
            continue
        while remaining:
            first = last = remaining.pop(0)
            while remaining and remaining[0] == last + 1:
                last = remaining.pop(0)
            result.append(_segment(o, first, last, o.occurrence_date, monday))
    for p in pairs:
        for o in items:
            source = intersects(o, p.source_date, p.source_start, p.source_end) and (p.action == "swap" or o.item_key in p.source_keys)
            target = p.action == "swap" and intersects(o, p.target_date, p.target_start, p.target_end)
            if not source and not target:
                continue
            first, last = (p.source_start, p.source_end) if source else (p.target_start, p.target_end)
            offset = p.target_start - p.source_start if source else p.source_start - p.target_start
            result.append(_segment(o, max(first, o.start_section) + offset, min(last, o.end_section) + offset, p.target_date if source else p.source_date, monday))
    return sorted(result, key=lambda o: (o.occurrence_date, o.start_section, o.item_key))


def preview_batch(items: list[WidgetOccurrence], request: BatchRequest, fingerprint: str) -> BatchPreview:
    from app.schedule_adjustment_models import AdjustmentRequest
    from app.schedule_adjustment_v2 import build_preview
    rows: list[BatchPairPreview] = []
    for p in request.pairs:
        if request.operation == "dayCover":
            from app.schedule_adjustment_v2 import apply_pair

            before = [o for o in items if o.occurrence_date in {p.source_date, p.target_date}]
            selected = [o for o in before if o.occurrence_date == p.source_date and o.item_key in p.source_keys]
            if len(selected) != len(p.source_keys) or not selected:
                raise ValueError("来源日期课程已变化或为空，请重新选择日期")
            rows.append(BatchPairPreview(
                pair=p,
                before=before,
                after=[o for o in apply_pair(items, p, request.first_week_start) if o.occurrence_date in {p.source_date, p.target_date}],
                conflicts=[o for o in before if o.occurrence_date == p.target_date],
                labels=["来源当天课程整体移到目标日期，覆盖目标当天课程；目标课程不会换回"],
            ))
            continue
        # 单项沿用已验证的来源、边界和冲突规则；V3 负责整批合并。
        single = AdjustmentRequest(schemaVersion=2, year=request.year, term=request.term, firstWeekStart=request.first_week_start, operation="day" if request.operation == "day" else "course", pairs=[AdjustmentPair.model_validate(p.model_dump(exclude={"item_id"}, by_alias=True))])
        row = build_preview(items, single, fingerprint).pairs[0]
        pair = p.model_copy(update={"action": "move"}) if p.action == "choose" and not row.conflicts else p
        rows.append(BatchPairPreview(pair=pair, before=row.before, after=row.after, conflicts=row.conflicts, labels=row.labels))
    pairs = [r.pair for r in rows]
    collisions = batch_conflicts(items, pairs)
    ready = not collisions and all(p.action != "choose" for p in pairs)
    days = {d for p in pairs for d in (p.source_date, p.target_date)}
    before = [o for o in items if o.occurrence_date in days]
    after = [o for o in apply_batch(items, pairs, request.first_week_start) if o.occurrence_date in days] if ready else before
    return BatchPreview(fingerprint=fingerprint, ready=ready, pairs=rows, affectedCount=len({key for p in pairs for key, _ in touched_sections(items, p)} | {o.item_key for row in rows for o in row.conflicts}), batchConflicts=collisions, before=before, after=after)
