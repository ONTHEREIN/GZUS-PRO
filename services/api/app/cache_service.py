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

# 兜底缓存的最大存活时间：超过则视为过期，避免故障时返回数月前的旧数据。
# 仅用于「失败兜底」场景（成功路径不主动读缓存），因此取较宽松的默认值。
DEFAULT_CACHE_MAX_AGE_SECONDS = 7 * 24 * 3600


def _is_stale(cached_at: datetime | None, max_age_seconds: int | None) -> bool:
    if max_age_seconds is None:
        max_age_seconds = DEFAULT_CACHE_MAX_AGE_SECONDS
    if max_age_seconds <= 0:
        return False
    if cached_at is None:
        return True
    # SQLite 读回的 datetime 为 naive（丢失时区），按 UTC 归一化后比较
    if cached_at.tzinfo is None:
        cached_at = cached_at.replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - cached_at).total_seconds()
    return age > max_age_seconds


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


def load_cache(
    student_id: str,
    resource: str,
    params: dict | None = None,
    max_age_seconds: int | None = None,
):
    params_hash = _compute_params_hash(params)
    cache_key = _make_cache_key(student_id, resource, params_hash)
    Session = _get_factory()
    with Session() as session:
        entry = session.execute(
            select(DataCache).where(DataCache.cache_key == cache_key)
        ).scalar_one_or_none()
        if entry is None:
            return None
        if _is_stale(entry.cached_at, max_age_seconds):
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
    student_id: str,
    resource: str,
    params: dict | None = None,
    max_age_seconds: int | None = None,
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
        if _is_stale(entry.cached_at, max_age_seconds):
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


# ─── 轮询器内存缓存 ─────────────────────────────────
# 从 jobs.py 迁出，使 main.py 无需为这几个类加载整个 jobs 依赖链
# （jobs → ecard_client → notice_utils → push），降低 Vercel 冷启动开销。


class NoticeCache:
    def __init__(self) -> None:
        self._titles_by_session: dict[str, set[str]] = {}

    def get_cached_titles(self, session_id: str) -> set[str]:
        return set(self._titles_by_session.get(session_id, set()))

    def update(self, session_id: str, titles: set[str]) -> None:
        self._titles_by_session[session_id] = set(titles)

    def remove(self, session_id: str) -> None:
        self._titles_by_session.pop(session_id, None)


class GradeUpdateCache:
    def __init__(self) -> None:
        self._grades_by_student: dict[str, dict[str, str]] = {}

    def get(self, student_id: str) -> dict[str, str]:
        return dict(self._grades_by_student.get(student_id, {}))

    def update(self, student_id: str, grades: dict[str, str]) -> None:
        self._grades_by_student[student_id] = dict(grades)

    def remove(self, student_id: str) -> None:
        self._grades_by_student.pop(student_id, None)


class ExamReminderCache:
    def __init__(self) -> None:
        self._reminded: dict[str, set[str]] = {}

    def is_reminded(self, session_id: str, exam_key: str) -> bool:
        return exam_key in self._reminded.get(session_id, set())

    def mark_reminded(self, session_id: str, exam_key: str) -> None:
        if session_id not in self._reminded:
            self._reminded[session_id] = set()
        self._reminded[session_id].add(exam_key)

    def remove(self, session_id: str) -> None:
        self._reminded.pop(session_id, None)
