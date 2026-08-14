from __future__ import annotations

import json
import logging
import re
import threading
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.config import get_settings
from app.database import DataCache, EcardBinding, get_sync_session_factory
from app.ecard_client import EcardApiError, EcardClient, EcardConfigurationError, EcardRoomRef
from app.routes.deps import require_session
from app.schemas import (
    EcardBindingRequest,
    EcardConsumptionResponse,
    EcardReminderRequest,
    EcardRoomItem,
    EcardSummary,
    EcardSummaryCacheRequest,
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
_ROOMS_PERSISTENT_CACHE_KEY = "ecard_rooms_all"
_ROOMS_PERSISTENT_TTL = 24 * 3600
_SUMMARY_CACHE_FIELDS = {
    "powerBalance",
    "powerUnit",
    "powerText",
    "coldWaterBalance",
    "coldWaterUnit",
    "coldWaterText",
    "hotWaterBalance",
    "hotWaterUnit",
    "hotWaterText",
    "updatedAt",
}


def _load_rooms_persistent(max_age: int | None = None) -> list[dict[str, str]]:
    try:
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(DataCache).filter(
                DataCache.cache_key == _ROOMS_PERSISTENT_CACHE_KEY
            ).first()
            if row is None:
                return []
            if max_age is not None and row.cached_at is not None:
                cached_at = row.cached_at
                if cached_at.tzinfo is None:
                    cached_at = cached_at.replace(tzinfo=timezone.utc)
                age = (datetime.now(timezone.utc) - cached_at).total_seconds()
                if age > max_age:
                    return []
            data = json.loads(row.response_json)
            if not isinstance(data, list):
                return []
            return [item for item in data if isinstance(item, dict)]
    except Exception as exc:
        logger.warning("ecard: load persistent rooms cache failed: %s", exc)
        return []


def _save_rooms_persistent(rooms: list[dict[str, str]]) -> None:
    try:
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(DataCache).filter(
                DataCache.cache_key == _ROOMS_PERSISTENT_CACHE_KEY
            ).first()
            payload = json.dumps(rooms, ensure_ascii=False)
            if row is None:
                db.add(DataCache(
                    cache_key=_ROOMS_PERSISTENT_CACHE_KEY,
                    student_id="",
                    resource="ecard_rooms",
                    response_json=payload,
                ))
            else:
                row.response_json = payload
                row.cached_at = datetime.now(timezone.utc)
            db.commit()
    except Exception as exc:
        logger.warning("ecard: save persistent rooms cache failed: %s", exc)


def _get_rooms_cached() -> list[dict[str, str]]:
    """Return the cached room list, refreshing if stale."""
    global _rooms_cache, _rooms_cache_at
    import time

    now = time.time()
    with _rooms_cache_lock:
        if _rooms_cache and now - _rooms_cache_at < _ROOMS_CACHE_TTL:
            return _rooms_cache

    persistent = _load_rooms_persistent(max_age=_ROOMS_PERSISTENT_TTL)
    if persistent:
        with _rooms_cache_lock:
            _rooms_cache = persistent
            _rooms_cache_at = now
        return persistent

    # Cache miss – fetch from ecard API (outside lock to avoid blocking)
    try:
        fresh = _client().rooms()
    except (EcardConfigurationError, EcardApiError):
        # If fetch fails, return stale cache if available
        with _rooms_cache_lock:
            if _rooms_cache:
                logger.warning("ecard: rooms fetch failed, serving stale cache")
                return _rooms_cache
        persistent = _load_rooms_persistent()
        if persistent:
            logger.warning("ecard: rooms fetch failed, serving persistent cache")
            with _rooms_cache_lock:
                _rooms_cache = persistent
                _rooms_cache_at = now
            return persistent
        raise

    with _rooms_cache_lock:
        _rooms_cache = fresh
        _rooms_cache_at = now
    _save_rooms_persistent(fresh)
    return fresh


def _student_info(session: AppSession) -> tuple[str, str]:
    # 优先使用会话持久化学号，其次客户端内存账号，避免每次都请求教务系统
    student_id = session.student_account or (
        getattr(session.client, "_account", None) if session.client else None
    )
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
        if session.client is None:
            logger.error("ecard: session.client is None for session %s", session.id[:8])
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="会话已过期，请重新登录",
            )
        try:
            info = session.client.get_info()
            if isinstance(info, dict):
                student_id = str(
                    info.get("studentId") or info.get("student_id") or info.get("sno") or ""
                )
                name = str(info.get("name") or info.get("xm") or name)
                logger.info("ecard: get_info returned student_id=%s name=%s", student_id, name)
        except AuthenticationError as exc:
            logger.warning("ecard: get_info auth failed for session %s: %s", session.id[:8], exc)
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
        except Exception as exc:
            # Stale JWXT cookies (expired session) → the downstream
            # call almost certainly failed because of invalid auth.
            # Return 401 so the frontend triggers a relogin rather
            # than cascading into 502 retry storms.
            logger.warning(
                "ecard: get_info failed for session %s: %s: %s — treating as expired session",
                session.id[:8],
                type(exc).__name__,
                exc,
            )
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="会话已过期，请重新登录",
            ) from exc

    if not student_id:
        logger.error("ecard: no student_id available for session %s", session.id[:8])
        raise HTTPException(status_code=502, detail="当前用户缺少学号")

    return student_id, name


def _client() -> EcardClient:
    try:
        # When ECARD_WORKER_PROXY_ORIGIN is empty, use direct mode (no Worker
        # proxy). This avoids the broken CF Worker → school fetch path that
        # times out after 20s. Direct mode calls the school server via httpx.
        settings = get_settings()
        proxy_origin = settings.ecard_worker_proxy_origin or ""
        return EcardClient(worker_proxy_origin=proxy_origin if proxy_origin else None)
    except EcardConfigurationError as exc:
        logger.error("ecard: configuration error: %s", exc)
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def _binding_for(student_id: str) -> EcardBinding | None:
    factory = get_sync_session_factory()
    with factory() as db:
        return db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()


def _clean_summary_cache(data: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in data.items() if key in _SUMMARY_CACHE_FIELDS}


def _summary_from_binding(binding: EcardBinding, student_id: str | None = None) -> dict[str, Any]:
    data: dict[str, Any] = {}
    if binding.last_summary_json:
        try:
            data = _clean_summary_cache(json.loads(binding.last_summary_json))
        except json.JSONDecodeError:
            data = {}
    # 如果 last_summary_json 中没有热水余额，尝试从独立缓存补充
    if data.get("hotWaterBalance") is None and binding.hot_water_balance_cache is not None:
        data["hotWaterBalance"] = binding.hot_water_balance_cache
        data["hotWaterUnit"] = "元"
        data["hotWaterText"] = f"{binding.hot_water_balance_cache:.2f}元"
    return {
        "status": "ok",
        "studentId": student_id,
        "roomId": binding.room_id,
        "roomDisplay": binding.room_display,
        "reminderEnabled": binding.reminder_enabled,
        "lowPowerThreshold": binding.low_power_threshold,
        "lowColdWaterThreshold": binding.low_cold_water_threshold,
        "lowHotWaterThreshold": binding.low_hot_water_threshold,
        "reminderTimes": json.loads(binding.reminder_times)
        if binding.reminder_times
        else ["08:00"],
        "reminderItems": json.loads(binding.reminder_items)
        if binding.reminder_items
        else ["power", "cold_water", "hot_water"],
        "updatedAt": binding.last_checked_at.isoformat() if binding.last_checked_at else None,
        **data,
    }


def refresh_binding(
    binding: EcardBinding, student_id: str, client: EcardClient | None = None
) -> dict[str, Any]:
    room_ref = EcardRoomRef.from_id(binding.room_id)
    logger.info("ecard: refreshing balance for student=%s room=%s", student_id, binding.room_id)
    summary = None
    api_error = None
    try:
        summary = (client or _client()).balance(room_ref, student_id)
    except EcardConfigurationError:
        raise
    except EcardApiError as exc:
        # API 返回错误码（如认证失败、房间不存在），不 fallback
        api_error = exc
        logger.warning("ecard: balance API error for student=%s: %s", student_id, exc)
    except Exception as exc:
        # 其他异常（如超时、网络错误），尝试 fallback
        api_error = exc
        logger.warning(
            "ecard: balance refresh failed for student=%s (will try cache fallback): %s",
            student_id, exc, exc_info=True
        )

    if summary is None:
        # API 调用失败，尝试从缓存恢复
        if binding.hot_water_balance_cache is not None:
            logger.info(
                "ecard: using cached hot_water_balance for student=%s: %.2f",
                student_id, binding.hot_water_balance_cache
            )
            # 从 last_summary_json 恢复其他字段，热水用缓存
            cached_data = {}
            if binding.last_summary_json:
                try:
                    cached_data = _clean_summary_cache(json.loads(binding.last_summary_json))
                except json.JSONDecodeError:
                    cached_data = {}
            summary = {
                **cached_data,
                "hotWaterBalance": binding.hot_water_balance_cache,
                "hotWaterUnit": "元",
                "hotWaterText": f"{binding.hot_water_balance_cache:.2f}元",
            }
        else:
            # 无缓存，抛出原始错误
            if api_error:
                raise api_error
            summary = {}

    # 更新缓存（如果成功获取了热水余额）
    hot_balance = summary.get("hotWaterBalance")
    if hot_balance is not None:
        binding.hot_water_balance_cache = float(hot_balance)
        binding.hot_water_cache_at = datetime.now(timezone.utc)

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
            r
            for r in all_rooms
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
            binding = EcardBinding(
                student_id=student_id, room_id=payload.room_id, room_display=payload.room_display
            )
            db.add(binding)
        else:
            binding.room_id = payload.room_id
            binding.room_display = payload.room_display
        db.flush()
        try:
            refresh_binding(binding, student_id)
        except EcardConfigurationError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except EcardApiError as exc:
            logger.warning(
                "ecard: bind_room balance unavailable for student=%s: %s",
                student_id,
                exc,
                exc_info=True,
            )
            db.commit()
            db.refresh(binding)
            return _summary_from_binding(binding, student_id)
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
            logger.warning(
                "ecard: refresh failed for student=%s, serving cached binding summary: %s",
                student_id,
                exc,
                exc_info=True,
            )
            return _summary_from_binding(binding, student_id)
        db.commit()
        db.refresh(binding)
        return _summary_from_binding(binding, student_id)


@router.patch("/summary-cache", response_model=EcardSummary)
def update_summary_cache(
    payload: EcardSummaryCacheRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    student_id, _ = _student_info(session)
    factory = get_sync_session_factory()
    with factory() as db:
        binding = db.query(EcardBinding).filter(EcardBinding.student_id == student_id).first()
        if binding is None:
            raise HTTPException(status_code=404, detail="请先绑定宿舍")

        existing: dict[str, Any] = {}
        if binding.last_summary_json:
            try:
                existing = json.loads(binding.last_summary_json)
            except json.JSONDecodeError:
                existing = {}

        existing = _clean_summary_cache(existing)
        update = payload.model_dump(by_alias=True, exclude_unset=True)
        existing.update({key: value for key, value in update.items() if value is not None})
        binding.last_summary_json = json.dumps(existing, ensure_ascii=False)
        binding.last_checked_at = datetime.now(timezone.utc)
        binding.updated_at = datetime.now(timezone.utc)
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
        logger.warning(
            "ecard: consumption unavailable for student=%s month=%s: %s",
            student_id,
            query_month,
            exc,
            exc_info=True,
        )
        return {"status": "limited", "message": "消费记录暂时不可用", "items": []}
