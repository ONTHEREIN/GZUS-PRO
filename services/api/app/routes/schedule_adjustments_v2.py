"""调课 V2 云端预览、原子提交与依赖撤销。"""

import hashlib
import json
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import TypeAdapter, ValidationError
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from app.database import (
    Base,
    ScheduleAdjustment,
    ScheduleAdjustmentScope,
    get_sync_engine,
    get_sync_session_factory,
    UserSettings,
)
from app.routes.deps import require_session
from app.routes.schedule_adjustments import _student_id, _to_response, read_adjustments
from app.schedule_adjustment_batch_models import BatchRequest
from app.schedule_adjustment_models import (
    AdjustmentCommit,
    AdjustmentMetadata,
    AdjustmentPair,
    AdjustmentPreview,
    AdjustmentRequest,
    RestorePreview,
    RestoreRequest,
)
from app.schedule_adjustment_v2 import build_preview, pair_dependencies, intersects
from app.schemas import ScheduleAdjustmentResponse
from app.sessions import AppSession
from app.widget_schedule import WidgetCourse, WidgetSnapshotRequest, effective_widget_schedule

router = APIRouter(prefix="/settings/schedule/adjustments/v2", tags=["schedule-adjustments"])


def _initialize() -> None:
    Base.metadata.create_all(
        get_sync_engine(), tables=[ScheduleAdjustment.__table__, ScheduleAdjustmentScope.__table__]
    )


def _lock_scope(db: Session, student_id: str, year: int, term: int) -> ScheduleAdjustmentScope:
    insert = pg_insert if db.get_bind().dialect.name == "postgresql" else sqlite_insert
    db.execute(
        insert(ScheduleAdjustmentScope)
        .values(student_id=student_id, year=year, term=term, revision=0)
        .on_conflict_do_nothing()
    )
    return db.execute(
        select(ScheduleAdjustmentScope)
        .where(
            ScheduleAdjustmentScope.student_id == student_id,
            ScheduleAdjustmentScope.year == year,
            ScheduleAdjustmentScope.term == term,
        )
        .with_for_update()
    ).scalar_one()


def _records(
    db: Session, student_id: str, year: int, term: int
) -> list[ScheduleAdjustmentResponse]:
    return [
        _to_response(row)
        for row in db.scalars(
            select(ScheduleAdjustment)
            .where(
                ScheduleAdjustment.student_id == student_id,
                ScheduleAdjustment.year == year,
                ScheduleAdjustment.term == term,
            )
            .order_by(ScheduleAdjustment.created_at, ScheduleAdjustment.id)
        )
    ]


def _require_first_week(
    db: Session, student_id: str, request: AdjustmentRequest | BatchRequest | RestoreRequest
) -> None:
    Base.metadata.create_all(get_sync_engine(), tables=[UserSettings.__table__])
    settings = db.scalar(select(UserSettings).where(UserSettings.student_id == student_id))
    if settings is None or not settings.first_weeks_json:
        return
    weeks = json.loads(settings.first_weeks_json)
    configured = weeks.get(f"{request.year}-{request.term}")
    if configured is None:
        return
    try:
        configured_date = date.fromisoformat(configured)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail="第一周设置日期无效，请在课表设置中重新选择") from exc
    configured_monday = configured_date - timedelta(days=configured_date.weekday())
    if configured_monday != request.first_week_start:
        raise HTTPException(
            status_code=409, detail="第一周设置已变化，请返回课表刷新后重新选择日期"
        )


async def _courses(
    request: AdjustmentRequest | BatchRequest | RestoreRequest, session: AppSession
) -> list[WidgetCourse]:
    from app.routes.academic import schedule

    rows = await schedule(
        year=str(request.year),
        term=str(request.term),
        week=None,
        request=None,
        refresh=False,
        session=session,
    )
    adapter = TypeAdapter(list[WidgetCourse])
    try:
        return (
            adapter.validate_json(rows.body)
            if isinstance(rows, JSONResponse)
            else adapter.validate_python(rows)
        )
    except ValidationError as exc:
        raise HTTPException(
            status_code=502,
            detail={
                "message": "学校课表字段无效，无法生成调课预览",
                "year": request.year,
                "term": request.term,
                "errors": exc.errors(include_input=False, include_url=False, include_context=False),
            },
        ) from exc


def _context(request: AdjustmentRequest | BatchRequest | RestoreRequest) -> WidgetSnapshotRequest:
    return WidgetSnapshotRequest(
        year=request.year,
        term=request.term,
        firstWeekStart=request.first_week_start,
        overrides=[],
        pendingAdjustments=[],
    )


def _fingerprint(
    courses: list[WidgetCourse],
    records: list[ScheduleAdjustmentResponse],
    context: WidgetSnapshotRequest,
) -> str:
    content = {
        "courses": [row.model_dump(mode="json", by_alias=True) for row in courses],
        "records": [row.model_dump(mode="json", by_alias=True) for row in records],
        "context": context.model_dump(mode="json", by_alias=True),
    }
    return hashlib.sha256(
        json.dumps(content, ensure_ascii=False, sort_keys=True).encode()
    ).hexdigest()


def _require_v2(records: list[ScheduleAdjustmentResponse]) -> None:
    if any(r.schema_version == 3 for r in records):
        raise HTTPException(status_code=409, detail="此学期包含批量调课，请升级客户端")


def _preview(
    courses: list[WidgetCourse],
    records: list[ScheduleAdjustmentResponse],
    request: AdjustmentRequest,
) -> AdjustmentPreview:
    _require_v2(records)
    context = _context(request)
    try:
        return build_preview(
            effective_widget_schedule(courses, context, records),
            request,
            _fingerprint(courses, records, context),
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("", response_model=list[ScheduleAdjustmentResponse])
def history(
    year: int = Query(..., ge=2000, le=3000),
    term: int = Query(..., ge=1, le=2),
    session: AppSession = Depends(require_session),
) -> list[ScheduleAdjustmentResponse]:
    records = read_adjustments(year, term, session)
    _require_v2(records)
    return records


@router.post("/preview", response_model=AdjustmentPreview)
async def preview(
    payload: AdjustmentRequest, session: AppSession = Depends(require_session)
) -> AdjustmentPreview:
    with get_sync_session_factory()() as db:
        _require_first_week(db, _student_id(session), payload)
    return _preview(
        await _courses(payload, session),
        read_adjustments(payload.year, payload.term, session),
        payload,
    )


@router.post("", response_model=ScheduleAdjustmentResponse, status_code=201)
async def commit(
    payload: AdjustmentCommit, session: AppSession = Depends(require_session)
) -> ScheduleAdjustmentResponse:
    _initialize()
    courses = await _courses(payload, session)
    request = AdjustmentRequest.model_validate(
        payload.model_dump(exclude={"client_id", "fingerprint"}, by_alias=True)
    )
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        scope = _lock_scope(db, student_id, payload.year, payload.term)
        _require_first_week(db, student_id, payload)
        _require_v2(_records(db, student_id, payload.year, payload.term))
        existing = db.scalar(
            select(ScheduleAdjustment).where(
                ScheduleAdjustment.student_id == student_id,
                ScheduleAdjustment.client_id == payload.client_id,
            )
        )
        if existing is not None:
            if (
                existing.metadata_json is None
                or _to_response(existing).metadata.request != request
            ):
                raise HTTPException(
                    status_code=409, detail="相同调课编号对应不同内容，请重新生成操作编号"
                )
            return _to_response(existing)
        result = _preview(courses, _records(db, student_id, payload.year, payload.term), request)
        if result.fingerprint != payload.fingerprint:
            raise HTTPException(
                status_code=409, detail="课表或调课记录已变化，请更新预览并重新确认"
            )
        if not result.ready:
            raise HTTPException(status_code=422, detail="请为每个冲突配对选择交换或覆盖")
        first = request.pairs[0]
        now = datetime.now(timezone.utc)
        row = ScheduleAdjustment(
            student_id=student_id,
            client_id=payload.client_id,
            year=payload.year,
            term=payload.term,
            source_date=first.source_date.isoformat(),
            target_date=first.target_date.isoformat(),
            moves_json="[]",
            source_occurrence_keys_json="[]",
            target_conflict_keys_json="[]",
            conflict_mode="coexist",
            status="active",
            revision=1,
            created_at=now,
            updated_at=now,
            metadata_json=AdjustmentMetadata(request=request, preview=result).model_dump_json(
                by_alias=True
            ),
        )
        db.add(row)
        scope.revision += 1
        db.commit()
        db.refresh(row)
        return _to_response(row)


def _pairs(record: ScheduleAdjustmentResponse) -> list[AdjustmentPair]:
    if record.metadata is not None:
        return record.metadata.request.pairs
    if record.moves:
        return [
            AdjustmentPair(
                sourceDate=p.source_date,
                targetDate=p.target_date,
                sourceStart=p.source_start,
                sourceEnd=p.source_end,
                targetStart=p.target_start,
                sourceKeys=record.source_occurrence_keys,
                action="swap"
                if record.conflict_mode == "swap"
                else "replace"
                if record.conflict_mode == "replaceConflicts"
                else "move",
            )
            for p in record.moves
        ]
    return [
        AdjustmentPair(
            sourceDate=record.source_date,
            targetDate=record.target_date,
            sourceStart=1,
            sourceEnd=16,
            targetStart=1,
            sourceKeys=record.source_occurrence_keys,
            action="move",
        )
    ]


def _dependent(first: ScheduleAdjustmentResponse, later: ScheduleAdjustmentResponse) -> bool:
    if first.schema_version == 3 and later.schema_version == 3:
        from app.schedule_adjustment_v3 import touched_sections
        original = {o.item_key: o for row in first.metadata.preview.pairs for o in row.before}
        changed = {key for p in first.metadata.request.pairs for key, _ in touched_sections(list(original.values()), p)}
        for p in later.metadata.request.pairs:
            if any(key == root or key.startswith(root + ':') or key.startswith(root + '->') for key in p.source_keys for root in changed):
                return True
            for a in first.metadata.request.pairs:
                if p.target_date == a.source_date and p.target_start <= a.source_end and a.source_start <= p.target_end:
                    return True
                if p.target_date == a.target_date and p.target_start <= a.target_end and a.target_start <= p.target_end:
                    return True
                if p.action == 'swap' and ((p.source_date == a.source_date and p.source_start <= a.source_end and a.source_start <= p.source_end) or (p.source_date == a.target_date and p.source_start <= a.target_end and a.target_start <= p.source_end)):
                    return True
        return False
    if pair_dependencies(_pairs(first), _pairs(later)):
        return True
    if first.metadata is None:
        return False
    metadata = first.metadata
    affected = {
        item.item_key
        for row in metadata.preview.pairs
        for item in row.before
        if intersects(item, row.pair.source_date, row.pair.source_start, row.pair.source_end)
        or intersects(item, row.pair.target_date, row.pair.target_start, row.pair.target_end)
    }
    return any(
        key == root or key.startswith(root + ":") or key.startswith(root + "->")
        for pair in _pairs(later)
        for key in pair.source_keys
        for root in affected
    )


def _restore_preview(
    courses: list[WidgetCourse],
    records: list[ScheduleAdjustmentResponse],
    request: RestoreRequest,
    client_id: str,
) -> RestorePreview:
    target = next((item for item in records if item.client_id == client_id), None)
    if target is None:
        raise HTTPException(status_code=404, detail="当前学期没有此调课记录")
    if target.revision != request.expected_revision or target.status != "active":
        raise HTTPException(status_code=409, detail="调课记录已变化或已撤销，请刷新记录")
    blockers = [
        item.client_id
        for item in records[records.index(target) + 1 :]
        if item.status == "active" and _dependent(target, item)
    ]
    context = _context(request)
    dates = {day for p in _pairs(target) for day in (p.source_date, p.target_date)}
    before = [
        item
        for item in effective_widget_schedule(courses, context, records)
        if item.occurrence_date in dates
    ]
    after = (
        []
        if blockers
        else [
            item
            for item in effective_widget_schedule(
                courses, context, [row for row in records if row.client_id != client_id]
            )
            if item.occurrence_date in dates
        ]
    )
    return RestorePreview(
        fingerprint=_fingerprint(courses, records, context),
        blockers=blockers,
        before=before,
        after=after,
    )


@router.post("/{client_id}/restore-preview", response_model=RestorePreview)
async def restore_preview(
    client_id: str, payload: RestoreRequest, session: AppSession = Depends(require_session)
) -> RestorePreview:
    with get_sync_session_factory()() as db:
        _require_first_week(db, _student_id(session), payload)
    _require_v2(read_adjustments(payload.year, payload.term, session))
    return _restore_preview(
        await _courses(payload, session),
        read_adjustments(payload.year, payload.term, session),
        payload,
        client_id,
    )


@router.post("/{client_id}/restore", response_model=ScheduleAdjustmentResponse)
async def restore(
    client_id: str, payload: RestoreRequest, session: AppSession = Depends(require_session)
) -> ScheduleAdjustmentResponse:
    _initialize()
    courses = await _courses(payload, session)
    student_id = _student_id(session)
    with get_sync_session_factory()() as db:
        scope = _lock_scope(db, student_id, payload.year, payload.term)
        _require_first_week(db, student_id, payload)
        records = _records(db, student_id, payload.year, payload.term)
        _require_v2(records)
        result = _restore_preview(courses, records, payload, client_id)
        if result.blockers:
            raise HTTPException(
                status_code=409,
                detail={"message": "请先撤销关联的后续调课", "blockers": result.blockers},
            )
        if result.fingerprint != payload.fingerprint:
            raise HTTPException(status_code=409, detail="课表已变化，请更新撤销预览并重新确认")
        row = db.scalars(
            select(ScheduleAdjustment).where(
                ScheduleAdjustment.student_id == student_id,
                ScheduleAdjustment.client_id == client_id,
            )
        ).one()
        row.status = "restored"
        row.revision += 1
        row.updated_at = datetime.now(timezone.utc)
        scope.revision += 1
        db.commit()
        db.refresh(row)
        return _to_response(row)
