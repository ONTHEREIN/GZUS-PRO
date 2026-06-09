from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime, timezone

from sqlalchemy import select

from app.database import DataCache, get_sync_session_factory

logger = logging.getLogger(__name__)

# Module-level scoped session for reuse within the same request context.
# Avoids creating a new Session for every single cache read/write.
_session_factory = None


def _get_factory():
    global _session_factory
    if _session_factory is None:
        _session_factory = get_sync_session_factory()
    return _session_factory


def reset_cache_factory():
    """Reset the cached session factory (used in tests when DB engine is reset)."""
    global _session_factory
    _session_factory = None


def _make_cache_key(student_id: str, resource: str, params_hash: str) -> str:
    return f"{student_id}:{resource}:{params_hash}"


def _compute_params_hash(params: dict | None) -> str:
    if not params:
        return ""
    raw = json.dumps(params, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _to_serializable(data):
    """Convert Pydantic models (and nested ones) to plain dicts for JSON serialization."""
    if hasattr(data, "model_dump"):
        return data.model_dump(by_alias=True)
    return data


def save_cache(student_id: str, resource: str, data, params: dict | None = None) -> None:
    params_hash = _compute_params_hash(params)
    cache_key = _make_cache_key(student_id, resource, params_hash)
    serializable = _to_serializable(data)
    response_json = json.dumps(serializable, ensure_ascii=False, default=str)
    Session = _get_factory()
    with Session() as session:
        existing = session.execute(
            select(DataCache).where(DataCache.cache_key == cache_key)
        ).scalar_one_or_none()
        if existing is not None:
            existing.response_json = response_json
            existing.cached_at = datetime.now(timezone.utc)
        else:
            session.add(DataCache(
                cache_key=cache_key,
                student_id=student_id,
                resource=resource,
                params_hash=params_hash,
                response_json=response_json,
            ))
        session.commit()


def load_cache(student_id: str, resource: str, params: dict | None = None):
    params_hash = _compute_params_hash(params)
    cache_key = _make_cache_key(student_id, resource, params_hash)
    Session = _get_factory()
    with Session() as session:
        entry = session.execute(
            select(DataCache).where(DataCache.cache_key == cache_key)
        ).scalar_one_or_none()
        if entry is None:
            return None
        try:
            data = json.loads(entry.response_json)
        except (json.JSONDecodeError, TypeError):
            logger.warning("Corrupt cache entry for key=%s", cache_key)
            return None
        if not isinstance(data, (dict, list)):
            logger.warning("Corrupt cache entry for key=%s (type=%s), discarding", cache_key, type(data).__name__)
            return None
        return data


def get_cached_at(student_id: str, resource: str, params: dict | None = None) -> datetime | None:
    params_hash = _compute_params_hash(params)
    cache_key = _make_cache_key(student_id, resource, params_hash)
    Session = _get_factory()
    with Session() as session:
        entry = session.execute(
            select(DataCache).where(DataCache.cache_key == cache_key)
        ).scalar_one_or_none()
        return entry.cached_at if entry else None


def load_and_get_cached_at(
    student_id: str, resource: str, params: dict | None = None,
) -> tuple[dict | list | None, datetime | None]:
    """Load cache data and cached_at timestamp in a single DB round-trip."""
    params_hash = _compute_params_hash(params)
    cache_key = _make_cache_key(student_id, resource, params_hash)
    Session = _get_factory()
    with Session() as session:
        entry = session.execute(
            select(DataCache).where(DataCache.cache_key == cache_key)
        ).scalar_one_or_none()
        if entry is None:
            return None, None
        try:
            data = json.loads(entry.response_json)
        except (json.JSONDecodeError, TypeError):
            logger.warning("Corrupt cache entry for key=%s", cache_key)
            return None, None
        if not isinstance(data, (dict, list)):
            logger.warning("Corrupt cache entry for key=%s (type=%s), discarding", cache_key, type(data).__name__)
            return None, None
        return data, entry.cached_at


def clear_cache_for_student(student_id: str) -> int:
    Session = _get_factory()
    with Session() as session:
        count = session.query(DataCache).filter(DataCache.student_id == student_id).delete()
        session.commit()
        return count
