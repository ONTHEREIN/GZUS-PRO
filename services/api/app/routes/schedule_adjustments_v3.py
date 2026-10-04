"""V3 批量预览、原子提交及兼容历史撤销。"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select

from app.database import ScheduleAdjustment, get_sync_session_factory
from app.routes.deps import require_session
from app.routes.schedule_adjustments import _student_id, _to_response, read_adjustments
from app.routes.schedule_adjustments_v2 import (
    _initialize, _lock_scope, _require_first_week, _courses, _context,
    _fingerprint, _records, _restore_preview,
)
from app.schedule_adjustment_batch_models import BatchRequest, BatchCommit, BatchPreview, BatchMetadata
from app.schedule_adjustment_models import RestoreRequest, RestorePreview
from app.schedule_adjustment_v3 import preview_batch
from app.schemas import ScheduleAdjustmentResponse
from app.sessions import AppSession
from app.widget_schedule import WidgetCourse, effective_widget_schedule

router = APIRouter(prefix="/settings/schedule/adjustments/v3", tags=["schedule-adjustments"])


def calculate(courses: list[WidgetCourse], records: list[ScheduleAdjustmentResponse], payload: BatchRequest) -> BatchPreview:
    context = _context(payload)
    try:
        return preview_batch(effective_widget_schedule(courses, context, records), payload, _fingerprint(courses, records, context))
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("", response_model=list[ScheduleAdjustmentResponse])
def history(year: int = Query(..., ge=2000, le=3000), term: int = Query(..., ge=1, le=2), session: AppSession = Depends(require_session)) -> list[ScheduleAdjustmentResponse]:
    return read_adjustments(year, term, session)


@router.post("/preview", response_model=BatchPreview)
async def preview(payload: BatchRequest, session: AppSession = Depends(require_session)) -> BatchPreview:
    with get_sync_session_factory()() as db:
        _require_first_week(db, _student_id(session), payload)
    return calculate(await _courses(payload, session), read_adjustments(payload.year, payload.term, session), payload)


@router.post("", response_model=ScheduleAdjustmentResponse, status_code=201)
async def commit(payload: BatchCommit, session: AppSession = Depends(require_session)) -> ScheduleAdjustmentResponse:
    _initialize()
    courses = await _courses(payload, session)
    request = BatchRequest.model_validate(payload.model_dump(exclude={"client_id", "fingerprint"}, by_alias=True))
    student = _student_id(session)
    with get_sync_session_factory()() as db:
        scope = _lock_scope(db, student, payload.year, payload.term)
        _require_first_week(db, student, payload)
        existing = db.scalar(select(ScheduleAdjustment).where(ScheduleAdjustment.student_id == student, ScheduleAdjustment.client_id == payload.client_id))
        if existing is not None:
            if not existing.metadata_json or _to_response(existing).metadata.request != request:
                raise HTTPException(status_code=409, detail="相同调课编号对应不同内容，请重新生成编号")
            return _to_response(existing)
        result = calculate(courses, _records(db, student, payload.year, payload.term), request)
        if result.fingerprint != payload.fingerprint:
            raise HTTPException(status_code=409, detail="课表已变化，请更新预览并重新确认")
        if not result.ready:
            raise HTTPException(status_code=422, detail="请处理批内冲突并选择每项冲突的交换或覆盖方式")
        now = datetime.now(timezone.utc)
        first = request.pairs[0]
        row = ScheduleAdjustment(student_id=student, client_id=payload.client_id, year=payload.year, term=payload.term, source_date=first.source_date.isoformat(), target_date=first.target_date.isoformat(), moves_json="[]", source_occurrence_keys_json="[]", target_conflict_keys_json="[]", conflict_mode="coexist", status="active", revision=1, created_at=now, updated_at=now, metadata_json=BatchMetadata(request=request, preview=result).model_dump_json(by_alias=True))
        db.add(row)
        scope.revision += 1
        db.commit()
        db.refresh(row)
        return _to_response(row)


@router.post("/{client_id}/restore-preview", response_model=RestorePreview)
async def restore_preview(client_id: str, payload: RestoreRequest, session: AppSession = Depends(require_session)) -> RestorePreview:
    with get_sync_session_factory()() as db:
        _require_first_week(db, _student_id(session), payload)
    return _restore_preview(await _courses(payload, session), read_adjustments(payload.year, payload.term, session), payload, client_id)


@router.post("/{client_id}/restore", response_model=ScheduleAdjustmentResponse)
async def restore(client_id: str, payload: RestoreRequest, session: AppSession = Depends(require_session)) -> ScheduleAdjustmentResponse:
    _initialize()
    courses = await _courses(payload, session)
    student = _student_id(session)
    with get_sync_session_factory()() as db:
        scope = _lock_scope(db, student, payload.year, payload.term)
        _require_first_week(db, student, payload)
        result = _restore_preview(courses, _records(db, student, payload.year, payload.term), payload, client_id)
        if result.blockers:
            raise HTTPException(status_code=409, detail={"message": "请先撤销关联的后续调课", "blockers": result.blockers})
        if result.fingerprint != payload.fingerprint:
            raise HTTPException(status_code=409, detail="课表已变化，请更新撤销预览")
        row = db.scalars(select(ScheduleAdjustment).where(ScheduleAdjustment.student_id == student, ScheduleAdjustment.client_id == client_id)).one()
        row.status = "restored"
        row.revision += 1
        row.updated_at = datetime.now(timezone.utc)
        scope.revision += 1
        db.commit()
        db.refresh(row)
        return _to_response(row)
