from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status

from app.database import Base, UserSettings, get_sync_engine, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import ScheduleSettings, ScheduleSettingsUpdate
from app.sessions import AppSession, student_id_of

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/settings", tags=["settings"])

# 生产环境（Vercel）init_db 会跳过全部建表工作（database.py 的 Vercel 分支），
# 新表在这里首次访问时幂等补建，避免新部署后 user_settings 表不存在导致 500。
_table_ready = False


def _ensure_table() -> None:
    global _table_ready
    if _table_ready:
        return
    engine = get_sync_engine()
    Base.metadata.create_all(engine, tables=[UserSettings.__table__])
    _table_ready = True


def _row_to_settings(row: UserSettings) -> dict[str, Any]:
    try:
        first_weeks = json.loads(row.first_weeks_json) if row.first_weeks_json else {}
    except json.JSONDecodeError:
        logger.warning("settings: invalid first_weeks_json for student=%s", row.student_id)
        first_weeks = {}
    if not isinstance(first_weeks, dict):
        first_weeks = {}
    return {
        "firstWeeks": {str(k): str(v) for k, v in first_weeks.items()},
        "autoWeek": row.auto_week,
        "onboardingCompleted": row.onboarding_completed,
    }


def _require_student_id(session: AppSession) -> str:
    student_id = student_id_of(session)
    if not student_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="会话已过期，请重新登录",
        )
    return student_id


@router.get("/schedule", response_model=ScheduleSettings)
def get_schedule_settings(
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    """获取当前用户的课表偏好设置；未保存过时返回默认值。"""
    student_id = _require_student_id(session)
    _ensure_table()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(UserSettings).filter(UserSettings.student_id == student_id).first()
        if row is None:
            return {"firstWeeks": {}, "autoWeek": True, "onboardingCompleted": False}
        return _row_to_settings(row)


@router.put("/schedule", response_model=ScheduleSettings)
def put_schedule_settings(
    payload: ScheduleSettingsUpdate,
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    """保存当前用户的课表偏好设置；firstWeeks 为合并语义（保留其他学期）。"""
    student_id = _require_student_id(session)
    _ensure_table()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(UserSettings).filter(UserSettings.student_id == student_id).first()
        if row is None:
            row = UserSettings(student_id=student_id)
            db.add(row)
        if payload.first_weeks is not None:
            try:
                first_weeks = json.loads(row.first_weeks_json) if row.first_weeks_json else {}
            except json.JSONDecodeError:
                first_weeks = {}
            if not isinstance(first_weeks, dict):
                first_weeks = {}
            first_weeks.update(payload.first_weeks)
            row.first_weeks_json = json.dumps(first_weeks, ensure_ascii=False)
        if payload.auto_week is not None:
            row.auto_week = payload.auto_week
        if payload.onboarding_completed is not None:
            row.onboarding_completed = payload.onboarding_completed
        row.updated_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(row)
        return _row_to_settings(row)
