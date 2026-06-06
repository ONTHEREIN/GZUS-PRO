from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status

logger = logging.getLogger(__name__)

from app.database import EcardBinding, get_sync_session_factory
from app.ecard_client import EcardApiError, EcardClient, EcardConfigurationError, EcardRoomRef
from app.routes.deps import require_session
from app.schemas import (
    EcardBindingRequest,
    EcardConsumptionResponse,
    EcardReminderRequest,
    EcardRoomItem,
    EcardSummary,
)
from app.school_client import AuthenticationError
from app.sessions import AppSession

router = APIRouter(prefix="/ecard", tags=["ecard"])


def _student_info(session: AppSession) -> tuple[str, str]:
    try:
        info = session.client.get_info()
    except AuthenticationError as exc:
        logger.warning("ecard: get_info auth failed for session: %s", exc)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except Exception as exc:
        logger.error("ecard: get_info failed: %s", exc, exc_info=True)
        raise HTTPException(status_code=502, detail="获取当前用户学号失败") from exc
    student_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
    if not student_id:
        logger.error("ecard: no student_id in get_info response: %s", info)
        raise HTTPException(status_code=502, detail="当前用户缺少学号")
    return student_id, str(info.get("name") or session.student_name or "")


def _client() -> EcardClient:
    try:
        return EcardClient()
    except EcardConfigurationError as exc:
        logger.error("ecard: configuration error: %s", exc)
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def _binding_for(student_id: str) -> EcardBinding | None:
    factory = get_sync_session_factory()
    with factory() as db:
        return db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()


def _summary_from_binding(binding: EcardBinding) -> dict[str, Any]:
    data: dict[str, Any] = {}
    if binding.last_summary_json:
        try:
            data = json.loads(binding.last_summary_json)
        except json.JSONDecodeError:
            data = {}
    return {
        "status": "ok",
        "roomId": binding.room_id,
        "roomDisplay": binding.room_display,
        "reminderEnabled": binding.reminder_enabled,
        "lowPowerThreshold": binding.low_power_threshold,
        "updatedAt": binding.last_checked_at.isoformat() if binding.last_checked_at else None,
        **data,
    }


def refresh_binding(binding: EcardBinding, student_id: str, client: EcardClient | None = None) -> dict[str, Any]:
    room_ref = EcardRoomRef.from_id(binding.room_id)
    logger.info("ecard: refreshing balance for student=%s room=%s", student_id, binding.room_id)
    try:
        summary = (client or _client()).balance(room_ref, student_id)
    except (EcardConfigurationError, EcardApiError):
        raise
    except Exception as exc:
        logger.error("ecard: balance refresh failed for student=%s: %s", student_id, exc, exc_info=True)
        raise
    binding.last_summary_json = json.dumps(summary, ensure_ascii=False)
    binding.last_checked_at = datetime.now(timezone.utc)
    binding.updated_at = datetime.now(timezone.utc)
    return summary


@router.get("/rooms", response_model=list[EcardRoomItem])
def rooms(session: AppSession = Depends(require_session)) -> list[dict[str, str]]:
    _student_info(session)
    try:
        return _client().rooms()
    except EcardConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except EcardApiError as exc:
        logger.error("ecard: rooms API error: %s", exc, exc_info=True)
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.post("/binding", response_model=EcardSummary)
def bind_room(
    payload: EcardBindingRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    try:
        EcardRoomRef.from_id(payload.room_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    factory = get_sync_session_factory()
    with factory() as db:
        binding = db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()
        if binding is None:
            binding = EcardBinding(student_id=student_id, room_id=payload.room_id, room_display=payload.room_display)
            db.add(binding)
        else:
            binding.room_id = payload.room_id
            binding.room_display = payload.room_display
        try:
            refresh_binding(binding, student_id)
        except EcardConfigurationError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except EcardApiError as exc:
            logger.error("ecard: bind_room balance error for student=%s: %s", student_id, exc, exc_info=True)
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        db.commit()
        db.refresh(binding)
        return _summary_from_binding(binding)


@router.get("/summary", response_model=EcardSummary)
def summary(session: AppSession = Depends(require_session)) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    binding = _binding_for(student_id)
    if binding is None:
        return {"status": "not_bound"}
    return _summary_from_binding(binding)


@router.post("/refresh", response_model=EcardSummary)
def refresh(session: AppSession = Depends(require_session)) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    factory = get_sync_session_factory()
    with factory() as db:
        binding = db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()
        if binding is None:
            logger.info("ecard: refresh skipped, no binding for student=%s", student_id)
            return {"status": "not_bound"}
        try:
            refresh_binding(binding, student_id)
        except EcardConfigurationError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except EcardApiError as exc:
            logger.error("ecard: refresh failed for student=%s: %s", student_id, exc, exc_info=True)
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        db.commit()
        db.refresh(binding)
        return _summary_from_binding(binding)


@router.patch("/reminder", response_model=EcardSummary)
def update_reminder(
    payload: EcardReminderRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    factory = get_sync_session_factory()
    with factory() as db:
        binding = db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()
        if binding is None:
            return {"status": "not_bound"}
        if payload.enabled is not None:
            binding.reminder_enabled = payload.enabled
        if payload.low_power_threshold is not None:
            binding.low_power_threshold = payload.low_power_threshold
        binding.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(binding)
        return _summary_from_binding(binding)


@router.get("/consumption", response_model=EcardConsumptionResponse)
def consumption(
    month: str | None = Query(default=None, pattern=r"^\d{4}-\d{2}$"),
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    binding = _binding_for(student_id)
    if binding is None:
        return {"status": "limited", "message": "请先绑定宿舍。", "items": []}
    query_month = month or datetime.now().strftime("%Y-%m")
    if not re.fullmatch(r"\d{4}-\d{2}", query_month):
        raise HTTPException(status_code=400, detail="月份格式应为 yyyy-mm")
    try:
        return _client().consumption(EcardRoomRef.from_id(binding.room_id), query_month)
    except EcardConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except EcardApiError as exc:
        logger.error("ecard: consumption failed for student=%s month=%s: %s", student_id, query_month, exc, exc_info=True)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
