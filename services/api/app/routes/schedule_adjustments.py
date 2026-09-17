from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.exc import IntegrityError

from app.database import Base, ScheduleAdjustment, get_sync_engine, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import (
    ScheduleAdjustmentCreate,
    ScheduleAdjustmentResponse,
    ScheduleAdjustmentUpdate,
)
from app.sessions import AppSession, student_id_of

router = APIRouter(prefix="/settings/schedule/adjustments", tags=["schedule-adjustments"])


def _ensure_table() -> None:
    # 测试和多进程环境可能会切换数据库引擎；create_all 本身幂等，
    # 不缓存进程级标记，避免新引擎被误判为已初始化。
    Base.metadata.create_all(get_sync_engine(), tables=[ScheduleAdjustment.__table__])


def _student_id(session: AppSession) -> str:
    value = student_id_of(session)
    if not value:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="会话已过期，请重新登录")
    return value


def _json_list(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise RuntimeError("课表调课记录 JSON 损坏") from exc
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise RuntimeError("课表调课记录字段格式无效")
    return parsed


def _to_response(row: ScheduleAdjustment) -> ScheduleAdjustmentResponse:
    return ScheduleAdjustmentResponse(
        clientId=row.client_id,
        year=row.year,
        term=row.term,
        sourceDate=row.source_date,
        targetDate=row.target_date,
        sourceOccurrenceKeys=_json_list(row.source_occurrence_keys_json),
        targetConflictKeys=_json_list(row.target_conflict_keys_json),
        conflictMode=row.conflict_mode,
        id=row.id,
        status=row.status,
        revision=row.revision,
        createdAt=row.created_at,
        updatedAt=row.updated_at,
    )


def _validate_dates(source_date: str, target_date: str) -> None:
    try:
        datetime.strptime(source_date, "%Y-%m-%d")
        datetime.strptime(target_date, "%Y-%m-%d")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="调课日期必须是有效日期") from exc
    if source_date == target_date:
        raise HTTPException(status_code=422, detail="源日期和目标日期必须不同")


@router.get("", response_model=list[ScheduleAdjustmentResponse])
def list_adjustments(
    year: int = Query(..., ge=2000, le=3000),
    term: int = Query(..., ge=1, le=2),
    session: AppSession = Depends(require_session),
) -> list[ScheduleAdjustmentResponse]:
    """读取当前学期调课记录；已还原记录保留，供历史页展示。"""
    _ensure_table()
    student_id = _student_id(session)
    factory = get_sync_session_factory()
    with factory() as db:
        rows = (
            db.query(ScheduleAdjustment)
            .filter(
                ScheduleAdjustment.student_id == student_id,
                ScheduleAdjustment.year == year,
                ScheduleAdjustment.term == term,
            )
            .order_by(ScheduleAdjustment.created_at.asc(), ScheduleAdjustment.id.asc())
            .all()
        )
        return [_to_response(row) for row in rows]


@router.post("", response_model=ScheduleAdjustmentResponse, status_code=status.HTTP_201_CREATED)
def create_adjustment(
    payload: ScheduleAdjustmentCreate,
    session: AppSession = Depends(require_session),
) -> ScheduleAdjustmentResponse:
    """创建或幂等返回客户端 UUID 对应的调课记录。"""
    _ensure_table()
    _validate_dates(payload.source_date, payload.target_date)
    student_id = _student_id(session)
    factory = get_sync_session_factory()
    with factory() as db:
        existing = (
            db.query(ScheduleAdjustment)
            .filter(
                ScheduleAdjustment.student_id == student_id,
                ScheduleAdjustment.client_id == payload.client_id,
            )
            .first()
        )
        if existing is not None:
            return _to_response(existing)
        now = datetime.now(timezone.utc)
        row = ScheduleAdjustment(
            student_id=student_id,
            client_id=payload.client_id,
            year=payload.year,
            term=payload.term,
            source_date=payload.source_date,
            target_date=payload.target_date,
            source_occurrence_keys_json=json.dumps(payload.source_occurrence_keys, ensure_ascii=False),
            target_conflict_keys_json=json.dumps(payload.target_conflict_keys, ensure_ascii=False),
            conflict_mode=payload.conflict_mode,
            status="active",
            revision=1,
            created_at=now,
            updated_at=now,
        )
        db.add(row)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            # A concurrent request with the same client UUID is safe to retry.
            existing = (
                db.query(ScheduleAdjustment)
                .filter(
                    ScheduleAdjustment.student_id == student_id,
                    ScheduleAdjustment.client_id == payload.client_id,
                )
                .first()
            )
            if existing is None:
                raise
            return _to_response(existing)
        db.refresh(row)
        return _to_response(row)


def _find_row(db, student_id: str, client_id: str) -> ScheduleAdjustment:
    row = (
        db.query(ScheduleAdjustment)
        .filter(
            ScheduleAdjustment.student_id == student_id,
            ScheduleAdjustment.client_id == client_id,
        )
        .with_for_update()
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="未找到课表调课记录")
    return row


@router.patch("/{client_id}", response_model=ScheduleAdjustmentResponse)
@router.put("/{client_id}", response_model=ScheduleAdjustmentResponse)
def update_adjustment(
    client_id: str,
    payload: ScheduleAdjustmentUpdate,
    session: AppSession = Depends(require_session),
) -> ScheduleAdjustmentResponse:
    _ensure_table()
    student_id = _student_id(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = _find_row(db, student_id, client_id)
        if row.revision != payload.expected_revision:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "message": "课表调课记录已被其他设备修改",
                    "server": _to_response(row).model_dump(mode="json", by_alias=True),
                },
            )
        source_date = payload.source_date or row.source_date
        target_date = payload.target_date or row.target_date
        _validate_dates(source_date, target_date)
        row.source_date = source_date
        row.target_date = target_date
        if payload.source_occurrence_keys is not None:
            row.source_occurrence_keys_json = json.dumps(payload.source_occurrence_keys, ensure_ascii=False)
        if payload.target_conflict_keys is not None:
            row.target_conflict_keys_json = json.dumps(payload.target_conflict_keys, ensure_ascii=False)
        if payload.conflict_mode is not None:
            row.conflict_mode = payload.conflict_mode
        row.revision += 1
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _to_response(row)


@router.post("/{client_id}/restore", response_model=ScheduleAdjustmentResponse)
def restore_adjustment(
    client_id: str,
    expected_revision: int = Query(..., alias="expectedRevision", ge=1),
    session: AppSession = Depends(require_session),
) -> ScheduleAdjustmentResponse:
    _ensure_table()
    student_id = _student_id(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = _find_row(db, student_id, client_id)
        if row.revision != expected_revision:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "message": "课表调课记录已被其他设备修改",
                    "server": _to_response(row).model_dump(mode="json", by_alias=True),
                },
            )
        row.status = "restored"
        row.revision += 1
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _to_response(row)
