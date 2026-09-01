"""仅供服务器本机 cron 调用的维护端点。"""
from __future__ import annotations

import json
import logging
import time
from datetime import datetime
from collections.abc import Callable
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Header, HTTPException

from app.config import get_settings
from app.database import record_maintenance_job_result

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/internal", tags=["internal"])


def _verify_internal_key(key: str | None) -> None:
    """验证仅保存在服务器环境变量中的维护密钥。"""
    expected = get_settings().internal_api_key
    if not expected:
        raise HTTPException(status_code=503, detail="Internal API key not configured")
    if not key or key != expected:
        raise HTTPException(status_code=403, detail="Invalid internal API key")


def _run_maintenance_job(job_name: str, runner: Callable[[], dict[str, object]]) -> dict[str, object]:
    """执行维护任务，并始终保存最后一次成功或失败结果。"""
    started_at = datetime.now(ZoneInfo("UTC"))
    started = time.perf_counter()
    try:
        result = runner()
    except Exception as exc:
        duration_ms = round((time.perf_counter() - started) * 1000)
        record_maintenance_job_result(job_name, started_at, duration_ms, str(exc)[:500], 0, 0)
        logger.exception("maintenance_job_failed", extra={"job_name": job_name, "duration_ms": duration_ms})
        raise
    duration_ms = round((time.perf_counter() - started) * 1000)
    record_maintenance_job_result(job_name, started_at, duration_ms, None, 0, 0)
    return result


@router.get("/cron/wechat-sync")
def wechat_sync_cron(x_internal_key: str | None = Header(None)) -> dict[str, object]:
    """由服务器 crontab 同步公众号文章。"""
    _verify_internal_key(x_internal_key)
    def run() -> dict[str, object]:
        from app.wechat_service import active_channel, sync_articles

        if active_channel() == "none":
            return {"ok": True, "reason": "wechat sync not configured", "added": 0}

        return {"ok": True, **sync_articles()}

    return _run_maintenance_job("wechat-sync", run)


@router.get("/cron/ecard-reminder")
def ecard_reminder_cron(x_internal_key: str | None = Header(None)) -> dict[str, object]:
    """由服务器 crontab 发送缓存余额的低余额提醒。"""
    _verify_internal_key(x_internal_key)
    def run() -> dict[str, object]:
        if not get_settings().ecard_openid:
            return {"ok": True, "reason": "ecard not configured", "processed": 0}
        from app.database import EcardBinding, get_sync_session_factory
        from app.jobs import prepare_ecard_reminders
        from app.push import send_push_to_student

        processed = 0
        notified = 0
        with get_sync_session_factory()() as db:
            bindings = db.query(EcardBinding).filter(EcardBinding.reminder_enabled.is_(True)).all()
            today_key = datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
            for binding in bindings:
                if not binding.last_summary_json:
                    continue
                try:
                    summary = json.loads(binding.last_summary_json)
                except (json.JSONDecodeError, TypeError):
                    logger.warning("invalid_ecard_summary", extra={"student_id": binding.student_id})
                    continue
                if not isinstance(summary, dict):
                    logger.warning("invalid_ecard_summary_type", extra={"student_id": binding.student_id})
                    continue

                pending, _ = prepare_ecard_reminders(binding, summary, today_key)
                if not pending:
                    continue
                for item_key, title, body in pending:
                    live_payload = {
                        "id": f"ecard_cron:{binding.student_id}:{today_key}:{item_key}",
                        "type": "ecard_reminder",
                        "studentId": binding.student_id,
                        "itemKey": item_key,
                        "liveUpdate": True,
                        "style": "progress",
                        "shortCriticalText": "水电",
                    }
                    try:
                        send_push_to_student(binding.student_id, title, body, live_payload)
                    except RuntimeError:
                        logger.exception("ecard_reminder_push_failed", extra={"student_id": binding.student_id})
                    else:
                        notified += 1
                processed += 1
            db.commit()

        return {"ok": True, "processed": processed, "notified": notified}

    return _run_maintenance_job("ecard-reminder", run)
