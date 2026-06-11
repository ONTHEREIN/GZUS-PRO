from __future__ import annotations

import json
import logging
import re
import threading
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status

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

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ecard", tags=["ecard"])

# ---------------------------------------------------------------------------
# Room list cache – the full list is ~6700 items / 880 KB; fetching it from
# the ecard API takes ~2.5 s.  Caching avoids repeated slow calls and lets
# us do server-side filtering so the client only receives a small payload.
# ---------------------------------------------------------------------------
_rooms_cache_lock = threading.Lock()
_rooms_cache: list[dict[str, str]] = []
_rooms_cache_at: float = 0.0
_ROOMS_CACHE_TTL = 3600  # seconds


def _get_rooms_cached() -> list[dict[str, str]]:
    """Return the cached room list, refreshing if stale."""
    global _rooms_cache, _rooms_cache_at
    import time

    now = time.time()
    with _rooms_cache_lock:
        if _rooms_cache and now - _rooms_cache_at < _ROOMS_CACHE_TTL:
            return _rooms_cache

    # Cache miss – fetch from ecard API (outside lock to avoid blocking)
    try:
        fresh = _client().rooms()
    except (EcardConfigurationError, EcardApiError):
        # If fetch fails, return stale cache if available
        with _rooms_cache_lock:
            if _rooms_cache:
                logger.warning("ecard: rooms fetch failed, serving stale cache")
                return _rooms_cache
        raise

    with _rooms_cache_lock:
        _rooms_cache = fresh
        _rooms_cache_at = now
    return fresh


def _student_info(session: AppSession) -> tuple[str, str]:
    # 优先从 session 缓存中获取学号，避免每次都请求教务系统
    student_id = getattr(session.client, "_account", None)
    if student_id:
        student_id = str(student_id)
    name = session.student_name or ""

    logger.info(
        "ecard: _student_info session=%s client=%s account=%s name=%s",
        session.id[:8] if session.id else "?",
        type(session.client).__name__ if session.client else "None",
        student_id or "(not cached)",
        name or "(empty)",
    )

    if not student_id:
        try:
            info = session.client.get_info()
            if isinstance(info, dict):
                student_id = str(info.get("studentId") or info.get("student_id") or info.get("sno") or "")
                name = str(info.get("name") or info.get("xm") or name)
                logger.info("ecard: get_info returned student_id=%s name=%s", student_id, name)
        except AuthenticationError as exc:
            logger.warning("ecard: get_info auth failed for session %s: %s", session.id[:8], exc)
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
        except Exception as exc:
            logger.error("ecard: get_info failed for session %s: %s: %s", session.id[:8], type(exc).__name__, exc, exc_info=True)
            raise HTTPException(
                status_code=502,
                detail=f"获取学号失败: {type(exc).__name__}: {exc}",
            ) from exc

    if not student_id:
        logger.error("ecard: no student_id available for session %s", session.id[:8])
        raise HTTPException(status_code=502, detail="当前用户缺少学号")

    return student_id, name


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


def _summary_from_binding(binding: EcardBinding, student_id: str | None = None) -> dict[str, Any]:
    data: dict[str, Any] = {}
    if binding.last_summary_json:
        try:
            data = json.loads(binding.last_summary_json)
        except json.JSONDecodeError:
            data = {}
    return {
        "status": "ok",
        "studentId": student_id,
        "roomId": binding.room_id,
        "roomDisplay": binding.room_display,
        "reminderEnabled": binding.reminder_enabled,
        "lowPowerThreshold": binding.low_power_threshold,
        "lowColdWaterThreshold": binding.low_cold_water_threshold,
        "lowHotWaterThreshold": binding.low_hot_water_threshold,
        "reminderTimes": json.loads(binding.reminder_times) if binding.reminder_times else ["08:00"],
        "reminderItems": json.loads(binding.reminder_items) if binding.reminder_items else ["power", "cold_water", "hot_water"],
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
def rooms(
    q: str | None = Query(default=None, max_length=50, description="搜索关键词"),
    limit: int = Query(default=100, ge=1, le=500, description="最大返回数量"),
    session: AppSession = Depends(require_session),
) -> list[dict[str, str]]:
    try:
        all_rooms = _get_rooms_cached()
    except EcardConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except EcardApiError as exc:
        logger.error("ecard: rooms API error: %s", exc, exc_info=True)
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    if q:
        keyword = q.strip().lower()
        filtered = [
            r for r in all_rooms
            if keyword in r.get("displayName", "").lower()
            or keyword in r.get("building", "").lower()
            or keyword in r.get("room", "").lower()
            or keyword in r.get("schoolArea", "").lower()
        ]
        return filtered[:limit]

    # No query – return limited list (full list is ~6700 items / 880 KB)
    return all_rooms[:limit]


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
        return _summary_from_binding(binding, student_id)


@router.get("/summary", response_model=EcardSummary)
def summary(session: AppSession = Depends(require_session)) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    binding = _binding_for(student_id)
    if binding is None:
        return {"status": "not_bound"}
    return _summary_from_binding(binding, student_id)


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
        return _summary_from_binding(binding, student_id)


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
        if payload.low_cold_water_threshold is not None:
            binding.low_cold_water_threshold = payload.low_cold_water_threshold
        if payload.low_hot_water_threshold is not None:
            binding.low_hot_water_threshold = payload.low_hot_water_threshold
        if payload.reminder_times is not None:
            binding.reminder_times = json.dumps(payload.reminder_times[:2])
        if payload.reminder_items is not None:
            binding.reminder_items = json.dumps(payload.reminder_items)
        binding.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(binding)
        return _summary_from_binding(binding, student_id)


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
