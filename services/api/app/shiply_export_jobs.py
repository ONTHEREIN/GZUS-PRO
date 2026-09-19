"""Shiply 资源包的异步生成、持久化与下载状态。"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from fastapi import FastAPI

from app.database import AdminAuditLog, ShiplyExportJob, get_sync_session_factory
from app.shiply_content import (
    SHIPLY_HOME_RESOURCE_KIND,
    SHIPLY_LOGIN_RESOURCE_KIND,
    ShiplyContentExportError,
    build_content_bundle,
    resource_key_for_kind,
)

logger = logging.getLogger(__name__)

SHIPLY_EXPORT_STATUS_QUEUED = "queued"
SHIPLY_EXPORT_STATUS_RUNNING = "running"
SHIPLY_EXPORT_STATUS_SUCCEEDED = "succeeded"
SHIPLY_EXPORT_STATUS_FAILED = "failed"
SHIPLY_EXPORT_RETENTION = timedelta(hours=24)
SHIPLY_RESOURCE_KINDS = frozenset({SHIPLY_LOGIN_RESOURCE_KIND, SHIPLY_HOME_RESOURCE_KIND})
_ACTIVE_STATUSES = (SHIPLY_EXPORT_STATUS_QUEUED, SHIPLY_EXPORT_STATUS_RUNNING)


@dataclass(frozen=True)
class ShiplyExportJobView:
    id: str
    resource_kind: str
    resource_key: str
    status: str
    created_at: str
    started_at: str | None
    completed_at: str | None
    generated_at: str | None
    expires_at: str | None
    filename: str | None
    sha256: str | None
    counts: dict[str, int] | None
    error: str | None

    def as_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "resource": self.resource_kind,
            "resourceKey": self.resource_key,
            "status": self.status,
            "createdAt": self.created_at,
            "startedAt": self.started_at,
            "completedAt": self.completed_at,
            "generatedAt": self.generated_at,
            "expiresAt": self.expires_at,
            "filename": self.filename,
            "sha256": self.sha256,
            "counts": self.counts,
            "error": self.error,
        }


@dataclass(frozen=True)
class ShiplyExportDownload:
    archive: bytes
    filename: str
    generated_at: str
    resource_key: str
    sha256: str
    counts: dict[str, int]


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def _counts_from_json(value: str | None) -> dict[str, int] | None:
    if value is None:
        return None
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Shiply 导出任务内容统计损坏: {exc}") from exc
    if not isinstance(decoded, dict) or any(not isinstance(item, int) for item in decoded.values()):
        raise RuntimeError("Shiply 导出任务内容统计格式损坏")
    return dict(decoded)


def _view_from_row(row: ShiplyExportJob) -> ShiplyExportJobView:
    created_at = _iso(row.created_at)
    if created_at is None:
        raise RuntimeError(f"Shiply 导出任务缺少创建时间: {row.id}")
    return ShiplyExportJobView(
        id=row.id,
        resource_kind=row.resource_kind,
        resource_key=row.resource_key,
        status=row.status,
        created_at=created_at,
        started_at=_iso(row.started_at),
        completed_at=_iso(row.completed_at),
        generated_at=_iso(row.generated_at),
        expires_at=_iso(row.expires_at),
        filename=row.filename,
        sha256=row.sha256,
        counts=_counts_from_json(row.counts_json),
        error=row.error,
    )


def _add_audit(
    db,
    operator_id: str,
    action: str,
    resource_key: str,
    detail: dict[str, object],
) -> None:
    db.add(
        AdminAuditLog(
            operator_id=operator_id,
            action=action,
            target_type="shiply_resource",
            target_id=resource_key,
            detail=json.dumps(detail, ensure_ascii=False, sort_keys=True),
        )
    )


def _cleanup_expired_jobs(db, now: datetime) -> None:
    db.query(ShiplyExportJob).filter(
        ShiplyExportJob.expires_at.is_not(None), ShiplyExportJob.expires_at <= now
    ).delete(synchronize_session=False)


def reconcile_shiply_export_jobs() -> None:
    """启动时回收过期文件，并显式结束上次进程遗留的活动任务。"""
    now = datetime.now(UTC)
    factory = get_sync_session_factory()
    with factory() as db:
        _cleanup_expired_jobs(db, now)
        abandoned = (
            db.query(ShiplyExportJob)
            .filter(ShiplyExportJob.status.in_(_ACTIVE_STATUSES))
            .all()
        )
        for row in abandoned:
            row.status = SHIPLY_EXPORT_STATUS_FAILED
            row.error = "服务器在资源包生成期间重启，请重新生成"
            row.completed_at = now
            row.expires_at = now + SHIPLY_EXPORT_RETENTION
            _add_audit(
                db,
                row.operator_id,
                "fail_shiply_resource_export",
                row.resource_key,
                {"jobId": row.id, "reason": "server_restarted"},
            )
        db.commit()


def create_or_get_shiply_export_job(
    resource_kind: str,
    operator_id: str,
) -> tuple[ShiplyExportJobView, bool]:
    if resource_kind not in SHIPLY_RESOURCE_KINDS:
        raise ValueError(f"不支持的 Shiply 资源类型: {resource_kind}")
    resource_key = resource_key_for_kind(resource_kind)
    now = datetime.now(UTC)
    factory = get_sync_session_factory()
    with factory() as db:
        _cleanup_expired_jobs(db, now)
        existing = (
            db.query(ShiplyExportJob)
            .filter(
                ShiplyExportJob.resource_kind == resource_kind,
                ShiplyExportJob.status.in_(_ACTIVE_STATUSES),
            )
            .order_by(ShiplyExportJob.created_at.desc())
            .first()
        )
        if existing is not None:
            db.commit()
            return _view_from_row(existing), False
        row = ShiplyExportJob(
            id=str(uuid.uuid4()),
            resource_kind=resource_kind,
            resource_key=resource_key,
            operator_id=operator_id,
            status=SHIPLY_EXPORT_STATUS_QUEUED,
            expires_at=now + SHIPLY_EXPORT_RETENTION,
        )
        db.add(row)
        _add_audit(
            db,
            operator_id,
            "request_shiply_resource_export",
            resource_key,
            {"jobId": row.id, "resource": resource_kind},
        )
        db.commit()
        return _view_from_row(row), True


def list_shiply_export_jobs(resource_kind: str | None) -> list[ShiplyExportJobView]:
    if resource_kind is not None and resource_kind not in SHIPLY_RESOURCE_KINDS:
        raise ValueError(f"不支持的 Shiply 资源类型: {resource_kind}")
    factory = get_sync_session_factory()
    with factory() as db:
        query = db.query(ShiplyExportJob)
        if resource_kind is not None:
            query = query.filter(ShiplyExportJob.resource_kind == resource_kind)
        rows = query.order_by(ShiplyExportJob.created_at.desc()).limit(20).all()
        return [_view_from_row(row) for row in rows]


def get_shiply_export_job(job_id: str) -> ShiplyExportJobView | None:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(ShiplyExportJob, job_id)
        return _view_from_row(row) if row is not None else None


def get_shiply_export_download(job_id: str) -> ShiplyExportDownload | None:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(ShiplyExportJob, job_id)
        if row is None or row.status != SHIPLY_EXPORT_STATUS_SUCCEEDED:
            return None
        if (
            row.archive is None
            or row.filename is None
            or row.generated_at is None
            or row.sha256 is None
            or row.counts_json is None
        ):
            raise RuntimeError(f"Shiply 导出任务产物不完整: {row.id}")
        counts = _counts_from_json(row.counts_json)
        if counts is None:
            raise RuntimeError(f"Shiply 导出任务内容统计缺失: {row.id}")
        return ShiplyExportDownload(
            archive=bytes(row.archive),
            filename=row.filename,
            generated_at=row.generated_at.isoformat(),
            resource_key=row.resource_key,
            sha256=row.sha256,
            counts=counts,
        )


def _mark_running(job_id: str) -> bool:
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(ShiplyExportJob, job_id)
        if row is None or row.status != SHIPLY_EXPORT_STATUS_QUEUED:
            return False
        row.status = SHIPLY_EXPORT_STATUS_RUNNING
        row.started_at = datetime.now(UTC)
        db.commit()
        return True


def _mark_succeeded(job_id: str, bundle) -> None:
    now = datetime.now(UTC)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(ShiplyExportJob, job_id)
        if row is None:
            return
        row.status = SHIPLY_EXPORT_STATUS_SUCCEEDED
        row.archive = bundle.archive
        row.filename = bundle.filename
        row.generated_at = datetime.fromisoformat(bundle.generated_at)
        row.sha256 = bundle.sha256
        row.counts_json = json.dumps(bundle.counts, ensure_ascii=False, sort_keys=True)
        row.error = None
        row.completed_at = now
        row.expires_at = now + SHIPLY_EXPORT_RETENTION
        _add_audit(
            db,
            row.operator_id,
            "export_shiply_resource",
            row.resource_key,
            {
                "jobId": row.id,
                "resource": row.resource_kind,
                "sha256": bundle.sha256,
                "generatedAt": bundle.generated_at,
                "counts": bundle.counts,
            },
        )
        db.commit()


def _mark_failed(job_id: str, error: str) -> None:
    now = datetime.now(UTC)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.get(ShiplyExportJob, job_id)
        if row is None:
            return
        row.status = SHIPLY_EXPORT_STATUS_FAILED
        row.error = error
        row.completed_at = now
        row.expires_at = now + SHIPLY_EXPORT_RETENTION
        _add_audit(
            db,
            row.operator_id,
            "fail_shiply_resource_export",
            row.resource_key,
            {"jobId": row.id, "resource": row.resource_kind, "error": error},
        )
        db.commit()


async def run_shiply_export_job(app: FastAPI, job_id: str, resource_kind: str) -> None:
    """在线程中生成资源包，避免同步网络下载占用 ASGI 事件循环。"""
    try:
        started = await asyncio.to_thread(_mark_running, job_id)
        if not started:
            return
        bundle = await asyncio.to_thread(build_content_bundle, resource_kind)
        await asyncio.to_thread(_mark_succeeded, job_id, bundle)
    except asyncio.CancelledError:
        raise
    except ShiplyContentExportError as exc:
        logger.warning("shiply_resource_export_failed", extra={"job_id": job_id, "error": str(exc)})
        await asyncio.to_thread(_mark_failed, job_id, str(exc))
    except Exception:
        logger.exception("shiply_resource_export_unexpected_error", extra={"job_id": job_id})
        await asyncio.to_thread(_mark_failed, job_id, "资源包生成出现未预期错误，请查看服务器日志")
    finally:
        app.state.shiply_export_tasks.pop(job_id, None)
