from __future__ import annotations

import base64
import logging
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import Response
from pydantic import AliasChoices, BaseModel, Field

from app import wechat_service
from app.config import get_settings
from app.database import (
    AdminAuditLog,
    LoginCarouselSlide,
    AdminNotice,
    AdminUser,
    AppSessionModel,
    BackgroundNotificationProfile,
    Base,
    DataCache,
    EcardBinding,
    MaintenanceJobStatus,
    WebPushSubscription,
    get_sync_engine,
    get_sync_session_factory,
)
from app.routes.deps import require_admin
from app.sessions import AppSession, student_id_of

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["admin"])

_tables_ready = False

# 管理后台图片上限：3MB（base64 后约 4MB）
ADMIN_IMAGE_MAX_BYTES = 3 * 1024 * 1024
LOGIN_SLIDE_PUBLISHED_LIMIT = 5


def ensure_admin_tables() -> None:
    global _tables_ready
    if _tables_ready:
        return
    engine = get_sync_engine()
    Base.metadata.create_all(
        engine,
        tables=[
            AdminUser.__table__,
            AdminAuditLog.__table__,
            AdminNotice.__table__,
            LoginCarouselSlide.__table__,
        ],
    )
    _seed_owner()
    _tables_ready = True


def _seed_owner() -> None:
    """ADMIN_SEED_OWNER 配置的学号（逗号分隔）启动时幂等写入 admin_users 作为 owner。"""
    raw = get_settings().admin_seed_owner.strip()
    if not raw:
        return
    factory = get_sync_session_factory()
    with factory() as db:
        for student_id in (part.strip() for part in raw.split(",") if part.strip()):
            exists = db.query(AdminUser).filter(AdminUser.student_id == student_id).first()
            if exists is None:
                db.add(AdminUser(student_id=student_id, role="owner"))
                logger.info("Seeded admin owner %s from ADMIN_SEED_OWNER", student_id)
        db.commit()


def admin_role_of(student_id: str | None) -> str | None:
    """查询学号在 admin_users 中的角色；不在白名单返回 None（登录时标记 is_admin 用）。"""
    if not student_id:
        return None
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminUser).filter(AdminUser.student_id == student_id).first()
        return row.role if row is not None else None


def _current_role(session: AppSession) -> str:
    """当前管理员会话的角色（默认 admin）。"""
    student_id = student_id_of(session)
    role = admin_role_of(student_id) if student_id else None
    return role or "admin"


def _log_audit(
    db,
    operator_id: str,
    action: str,
    target_type: str | None = None,
    target_id: str | None = None,
    detail: str | None = None,
) -> None:
    db.add(
        AdminAuditLog(
            operator_id=operator_id,
            action=action,
            target_type=target_type,
            target_id=target_id,
            detail=detail,
        )
    )


def _session_row_to_dict(row: AppSessionModel) -> dict[str, Any]:
    return {
        "id": row.id,
        "studentAccount": row.student_account,
        "studentName": row.student_name,
        "isAdmin": bool(getattr(row, "is_admin", False)),
        "createdAt": row.created_at,
        "lastActiveAt": row.last_active_at,
        "revokedAt": row.revoked_at,
        "revokedReason": row.revoked_reason,
    }


# ─── 请求/响应模型 ─────────────────────────────────────────────

class AdminMeResponse(BaseModel):
    is_admin: bool = True
    role: str
    student_id: str


class AdminUserPayload(BaseModel):
    student_id: str = Field(min_length=1, max_length=100, alias="studentId")
    role: str = Field(default="admin", pattern="^(owner|admin)$")


# ─── 端点 ──────────────────────────────────────────────────────

@router.get("/me", response_model=AdminMeResponse)
def admin_me(
    session: AppSession = Depends(require_admin),
) -> AdminMeResponse:
    """当前会话的管理员身份与角色（前端恢复会话后确认 isAdmin 用）。"""
    student_id = student_id_of(session)
    return AdminMeResponse(role=_current_role(session), student_id=student_id)


@router.get("/overview")
def admin_overview(
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """总览统计：会话/推送/水电费/缓存/管理员数量。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    now_utc = datetime.now(UTC)
    today_start = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    active_since = now_utc - timedelta(seconds=get_settings().session_ttl_seconds)
    with factory() as db:
        total_sessions = db.query(AppSessionModel).count()
        active_sessions = (
            db.query(AppSessionModel)
            .filter(AppSessionModel.last_active_at >= active_since)
            .filter(AppSessionModel.revoked_at.is_(None))
            .count()
        )
        sessions_today = db.query(AppSessionModel).filter(AppSessionModel.created_at >= today_start).count()
        revoked_sessions = db.query(AppSessionModel).filter(AppSessionModel.revoked_at.is_not(None)).count()
        web_push = db.query(WebPushSubscription).count()
        ecard_bindings = db.query(EcardBinding).count()
        cache_entries = db.query(DataCache).count()
        admin_users = db.query(AdminUser).count()
    return {
        "totalSessions": total_sessions,
        "activeSessions": active_sessions,
        "sessionsToday": sessions_today,
        "revokedSessions": revoked_sessions,
        "webPushSubscriptions": web_push,
        "ecardBindings": ecard_bindings,
        "cacheEntries": cache_entries,
        "adminUsers": admin_users,
        "generatedAt": now_utc,
    }


@router.get("/sessions")
def admin_sessions(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> dict[str, Any]:
    """会话列表（按创建时间倒序，简单分页）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(AppSessionModel).count()
        rows = (
            db.query(AppSessionModel)
            .order_by(AppSessionModel.created_at.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        items = [_session_row_to_dict(row) for row in rows]
    return {"total": total, "items": items}


@router.post("/sessions/{session_id}/revoke")
def revoke_session(
    session_id: str,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """强制下线一个会话（写审计日志；admin 不能踢 owner，不能踢自己）。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AppSessionModel).filter(AppSessionModel.id == session_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="会话不存在")
        if row.revoked_at is not None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="会话已下线")
        if row.id == session.id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="不能下线自己的会话")
        if _current_role(session) != "owner" and bool(getattr(row, "is_admin", False)):
            target_role = admin_role_of(row.student_account) if row.student_account else None
            if target_role == "owner":
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="不能下线 owner 管理员")
        credential_fingerprint = row.credential_fingerprint

    request.app.state.sessions.revoke(session_id, reason="admin_kick")
    if credential_fingerprint:
        request.app.state.sessions.revoke_credential(credential_fingerprint, reason="admin_kick")

    with factory() as db:
        if credential_fingerprint:
            db.query(BackgroundNotificationProfile).filter(
                BackgroundNotificationProfile.credential_fingerprint == credential_fingerprint
            ).delete()
        _log_audit(
            db,
            operator_id=operator_id,
            action="revoke_session",
            target_type="session",
            target_id=session_id,
        )
        db.commit()
    return {"ok": True, "sessionId": session_id}


@router.get("/users")
def admin_users_list(
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """管理员白名单列表（含角色与创建时间）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        rows = db.query(AdminUser).order_by(AdminUser.created_at.asc()).all()
        items = [
            {
                "studentId": row.student_id,
                "role": row.role,
                "createdAt": row.created_at,
            }
            for row in rows
        ]
    return {"items": items}


@router.post("/users", status_code=status.HTTP_201_CREATED)
def admin_users_add(
    payload: AdminUserPayload,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """添加管理员（仅 owner）。"""
    ensure_admin_tables()
    if _current_role(session) != "owner":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="仅 owner 可添加管理员")
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        exists = db.query(AdminUser).filter(AdminUser.student_id == payload.student_id).first()
        if exists is not None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="该学号已是管理员")
        db.add(AdminUser(student_id=payload.student_id, role=payload.role))
        _log_audit(
            db,
            operator_id=operator_id,
            action="add_admin",
            target_type="admin_user",
            target_id=payload.student_id,
            detail=payload.role,
        )
        db.commit()
    logger.info("Admin %s added admin user %s (role=%s)", operator_id, payload.student_id, payload.role)
    return {"ok": True, "studentId": payload.student_id, "role": payload.role}


@router.delete("/users/{student_id}")
def admin_users_remove(
    student_id: str,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """删除管理员（仅 owner；不能删自己，不能删最后一个 owner）。"""
    ensure_admin_tables()
    if _current_role(session) != "owner":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="仅 owner 可删除管理员")
    operator_id = student_id_of(session)
    if student_id == operator_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="不能删除自己的管理员身份")
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminUser).filter(AdminUser.student_id == student_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="该学号不是管理员")
        if row.role == "owner":
            owner_count = (
                db.query(AdminUser).filter(AdminUser.role == "owner").count()
            )
            if owner_count <= 1:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="不能删除最后一个 owner",
                )
        db.delete(row)
        _log_audit(
            db,
            operator_id=operator_id,
            action="remove_admin",
            target_type="admin_user",
            target_id=student_id,
        )
        db.commit()
    logger.info("Admin %s removed admin user %s", operator_id, student_id)
    return {"ok": True, "studentId": student_id}


@router.get("/push")
def admin_push(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
) -> dict[str, Any]:
    """Web Push 订阅列表。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        web_count = db.query(WebPushSubscription).count()
        web_rows = (
            db.query(WebPushSubscription)
            .order_by(WebPushSubscription.created_at.desc())
            .limit(limit)
            .all()
        )
        web_items = [
            {
                "studentId": row.student_id,
                "endpoint": row.endpoint[:48] + "…" if len(row.endpoint or "") > 48 else row.endpoint,
                "userAgent": row.user_agent,
                "createdAt": row.created_at,
            }
            for row in web_rows
        ]
    return {
        "webCount": web_count,
        "web": web_items,
    }


@router.get("/cache")
def admin_cache(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> dict[str, Any]:
    """数据库缓存条目列表（data_cache 表）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(DataCache).count()
        rows = (
            db.query(DataCache)
            .order_by(DataCache.cached_at.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        items = [
            {
                "cacheKey": row.cache_key,
                "studentId": row.student_id,
                "resource": row.resource,
                "cachedAt": row.cached_at,
            }
            for row in rows
        ]
    return {"total": total, "items": items}


@router.post("/cache/clear")
def admin_cache_clear(
    session: AppSession = Depends(require_admin),
    resource: str | None = Query(None, description="仅清空指定资源（如 schedule/grades）"),
) -> dict[str, Any]:
    """清空数据库缓存（可选按 resource 过滤；写审计日志）。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        query = db.query(DataCache)
        if resource:
            query = query.filter(DataCache.resource == resource)
        deleted = query.delete(synchronize_session=False)
        _log_audit(
            db,
            operator_id=operator_id,
            action="clear_cache",
            target_type="data_cache",
            target_id=resource or "*",
            detail=f"deleted={deleted}",
        )
        db.commit()
    logger.info("Admin %s cleared cache (resource=%s, deleted=%d)", operator_id, resource or "*", deleted)
    return {"ok": True, "deleted": deleted}


@router.get("/ecard")
def admin_ecard(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> dict[str, Any]:
    """水电费绑定列表与统计。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(EcardBinding).count()
        reminder_enabled = db.query(EcardBinding).filter(EcardBinding.reminder_enabled.is_(True)).count()
        rows = (
            db.query(EcardBinding)
            .order_by(EcardBinding.updated_at.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        items = [
            {
                "studentId": row.student_id,
                "roomDisplay": row.room_display,
                "reminderEnabled": row.reminder_enabled,
                "lowPowerThreshold": row.low_power_threshold,
                "lastCheckedAt": row.last_checked_at,
                "updatedAt": row.updated_at,
            }
            for row in rows
        ]
    return {
        "total": total,
        "reminderEnabled": reminder_enabled,
        "items": items,
    }


@router.get("/status")
def admin_status(
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """系统状态（脱敏：不暴露数据库地址/密钥等敏感信息）。"""
    settings = get_settings()
    factory = get_sync_session_factory()
    with factory() as db:
        jobs = db.query(MaintenanceJobStatus).order_by(MaintenanceJobStatus.job_name).all()
        job_statuses = [
            {
                "name": row.job_name,
                "lastStartedAt": row.last_started_at,
                "lastSucceededAt": row.last_succeeded_at,
                "lastDurationMs": row.last_duration_ms,
                "lastError": row.last_error,
                "lastProcessed": row.last_processed,
                "lastDelivered": row.last_delivered,
            }
            for row in jobs
        ]
        background_notification_profiles = db.query(BackgroundNotificationProfile).count()
    from app.apns_service import apns_configuration_error, is_apns_enabled
    from app.push import is_web_push_enabled
    return {
        "status": "ok",
        "debug": settings.debug,
        "runtime": "self_hosted",
        "timeUtc": datetime.now(UTC),
        "sessionTtlSeconds": settings.session_ttl_seconds,
        "appVersion": settings.app_latest_version,
        "appBuild": settings.app_latest_build,
        "maintenanceJobs": job_statuses,
        "backgroundNotificationProfiles": background_notification_profiles,
        "webPushEnabled": is_web_push_enabled(),
        "apnsEnabled": is_apns_enabled(),
        "apnsError": apns_configuration_error(),
    }


@router.get("/audit-log")
def admin_audit_log(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
) -> dict[str, Any]:
    """敏感操作审计日志（按时间倒序）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(AdminAuditLog).count()
        rows = (
            db.query(AdminAuditLog)
            .order_by(AdminAuditLog.created_at.desc())
            .limit(limit)
            .all()
        )
        items = [
            {
                "operatorId": row.operator_id,
                "action": row.action,
                "targetType": row.target_type,
                "targetId": row.target_id,
                "detail": row.detail,
                "createdAt": row.created_at,
            }
            for row in rows
        ]
    return {"total": total, "items": items}


# ─── 校历/通知上传（图片为主） ──────────────────────────────────


class AdminNoticePayload(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=2000)
    image_data: str | None = Field(
        default=None,
        max_length=6 * 1024 * 1024,
        validation_alias=AliasChoices("imageData", "image_data"),
    )
    image_mime: str | None = Field(
        default=None,
        max_length=100,
        validation_alias=AliasChoices("imageMime", "image_mime"),
    )
    is_pinned: bool = Field(
        default=False,
        validation_alias=AliasChoices("isPinned", "is_pinned"),
    )
    published: bool = Field(
        default=True,
        validation_alias=AliasChoices("published"),
    )


def _notice_row_to_dict(row: AdminNotice, include_image: bool = False) -> dict[str, Any]:
    data: dict[str, Any] = {
        "id": row.id,
        "title": row.title,
        "description": row.description,
        "coverUrl": f"/admin/notices/{row.id}/image" if row.image_data else None,
        "imageMime": row.image_mime,
        "isPinned": row.is_pinned,
        "published": row.published,
        "createdAt": row.created_at.isoformat() if row.created_at else None,
        "updatedAt": row.updated_at.isoformat() if row.updated_at else None,
    }
    if include_image and row.image_data:
        data["imageBase64"] = row.image_data
        data["imageMime"] = row.image_mime
    return data


@router.get("/notices")
def admin_notices_list(
    session: AppSession = Depends(require_admin),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> dict[str, Any]:
    """校历/通知列表（管理员视角，含未发布）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(AdminNotice).count()
        rows = (
            db.query(AdminNotice)
            .order_by(AdminNotice.is_pinned.desc(), AdminNotice.id.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        items = [_notice_row_to_dict(row) for row in rows]
    return {"total": total, "items": items}


@router.post("/notices", status_code=status.HTTP_201_CREATED)
def admin_notices_create(
    payload: AdminNoticePayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """上传校历/通知（标题+说明+base64 图片）。"""
    ensure_admin_tables()
    image_data = payload.image_data
    if image_data:
        # 去掉 data URL 前缀（data:image/png;base64,xxx）
        if image_data.startswith("data:"):
            header, _, rest = image_data.partition(",")
            if not payload.image_mime and ";" in header:
                mime = header.split(";", 1)[0].split(":", 1)[-1]
                payload.image_mime = mime or None
            image_data = rest
        try:
            raw_len = len(base64.b64decode(image_data))
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"图片 base64 解析失败: {exc}")
        if raw_len > ADMIN_IMAGE_MAX_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail="图片不能超过 3MB",
            )
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = AdminNotice(
            title=payload.title,
            description=payload.description,
            image_data=image_data,
            image_mime=payload.image_mime,
            is_pinned=payload.is_pinned,
            published=payload.published,
        )
        db.add(row)
        _log_audit(
            db,
            operator_id=operator_id,
            action="create_notice",
            target_type="admin_notice",
            target_id=str(row.id),
            detail=payload.title[:200],
        )
        db.commit()
        db.refresh(row)
    logger.info("Admin %s created notice #%s", operator_id, row.id)
    return _notice_row_to_dict(row)


@router.put("/notices/{notice_id}")
def admin_notices_update(
    notice_id: int,
    payload: AdminNoticePayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """更新校历/通知（部分字段传 None 表示不修改）。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminNotice).filter(AdminNotice.id == notice_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="通知不存在")
        if payload.title:
            row.title = payload.title
        if payload.description is not None:
            row.description = payload.description
        if payload.image_data:
            image_data = payload.image_data
            if image_data.startswith("data:"):
                header, _, rest = image_data.partition(",")
                if not payload.image_mime and ";" in header:
                    mime = header.split(";", 1)[0].split(":", 1)[-1]
                    payload.image_mime = mime or None
                image_data = rest
            try:
                raw_len = len(base64.b64decode(image_data))
            except Exception as exc:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"图片 base64 解析失败: {exc}")
            if raw_len > ADMIN_IMAGE_MAX_BYTES:
                raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="图片不能超过 3MB")
            row.image_data = image_data
            row.image_mime = payload.image_mime
        if payload.is_pinned is not None:
            row.is_pinned = payload.is_pinned
        if payload.published is not None:
            row.published = payload.published
        row.updated_at = datetime.now(UTC)
        _log_audit(
            db,
            operator_id=operator_id,
            action="update_notice",
            target_type="admin_notice",
            target_id=str(notice_id),
            detail=payload.title[:200] or row.title[:200],
        )
        db.commit()
        db.refresh(row)
    return _notice_row_to_dict(row)


@router.delete("/notices/{notice_id}")
def admin_notices_delete(
    notice_id: int,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """删除校历/通知。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminNotice).filter(AdminNotice.id == notice_id).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="通知不存在")
        title = row.title
        db.delete(row)
        _log_audit(
            db,
            operator_id=operator_id,
            action="delete_notice",
            target_type="admin_notice",
            target_id=str(notice_id),
            detail=title[:200],
        )
        db.commit()
    logger.info("Admin %s deleted notice #%s", operator_id, notice_id)
    return {"ok": True, "id": notice_id}


@router.get("/notices/{notice_id}/image")
def admin_notice_image(notice_id: int) -> Response:
    """校历/通知图片（公开二进制返回，供 App 展示；无需管理员权限）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(AdminNotice).filter(AdminNotice.id == notice_id).first()
        if row is None or not row.image_data:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="图片不存在")
        try:
            raw = base64.b64decode(row.image_data)
        except Exception:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="图片数据损坏")
        mime = row.image_mime or "image/png"
    return Response(content=raw, media_type=mime)


def list_published_admin_notices() -> list[dict]:
    """供 /academic/notices 并入：已发布的校历/通知（置顶优先，按创建倒序）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        rows = (
            db.query(AdminNotice)
            .filter(AdminNotice.published.is_(True))
            .order_by(AdminNotice.is_pinned.desc(), AdminNotice.id.desc())
            .all()
        )
        return [
            {
                "category": "校历",
                "title": row.title,
                "date": row.created_at.strftime("%Y-%m-%d") if row.created_at else None,
                "url": None,
                "summary": row.description,
                "coverUrl": f"/admin/notices/{row.id}/image" if row.image_data else None,
                "source": "admin",
                "isPinned": row.is_pinned,
            }
            for row in rows
        ]


# ─── 登录页轮播管理 ─────────────────────────────────────────────


class AdminLoginSlideCreatePayload(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=500)
    image_data: str = Field(
        min_length=1,
        max_length=6 * 1024 * 1024,
        validation_alias=AliasChoices("imageData", "image_data"),
    )
    image_mime: str = Field(
        min_length=1,
        max_length=100,
        validation_alias=AliasChoices("imageMime", "image_mime"),
    )
    published: bool = True


class AdminLoginSlideUpdatePayload(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=500)
    image_data: str | None = Field(
        default=None,
        max_length=6 * 1024 * 1024,
        validation_alias=AliasChoices("imageData", "image_data"),
    )
    image_mime: str | None = Field(
        default=None,
        max_length=100,
        validation_alias=AliasChoices("imageMime", "image_mime"),
    )
    published: bool | None = None


class AdminLoginSlideOrderPayload(BaseModel):
    ids: list[int] = Field(min_length=0, max_length=100)


def _decode_admin_image(image_data: str, image_mime: str | None) -> tuple[str, str]:
    """校验并规范化管理员提交的 base64 图片。"""
    normalized_data = image_data
    normalized_mime = image_mime
    if normalized_data.startswith("data:"):
        header, _, normalized_data = normalized_data.partition(",")
        if not normalized_data:
            raise HTTPException(status_code=400, detail="图片 data URL 缺少数据")
        if normalized_mime is None and ";" in header:
            normalized_mime = header.split(";", 1)[0].split(":", 1)[-1] or None
    if normalized_mime is None:
        raise HTTPException(status_code=400, detail="图片缺少 MIME 类型")
    try:
        raw_image = base64.b64decode(normalized_data, validate=True)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="图片 base64 解析失败") from exc
    if len(raw_image) > ADMIN_IMAGE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="图片不能超过 3MB")
    return normalized_data, normalized_mime


def _login_slide_to_dict(row: LoginCarouselSlide) -> dict[str, Any]:
    return {
        "id": row.id,
        "title": row.title,
        "description": row.description,
        "imageUrl": f"/admin/login-slides/{row.id}/image",
        "imageMime": row.image_mime,
        "sortOrder": row.sort_order,
        "published": row.published,
        "createdAt": row.created_at.isoformat() if row.created_at else None,
        "updatedAt": row.updated_at.isoformat() if row.updated_at else None,
    }


def _published_login_slide_count(db) -> int:
    return db.query(LoginCarouselSlide).filter(LoginCarouselSlide.published.is_(True)).count()


def _validate_login_slide_publication(db, published: bool, current_published: bool) -> None:
    if not published or current_published:
        return
    if _published_login_slide_count(db) >= LOGIN_SLIDE_PUBLISHED_LIMIT:
        raise HTTPException(status_code=400, detail="最多只能发布 5 张登录轮播图")


@router.get("/login-slides")
def admin_login_slides_list(
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """登录页轮播列表（管理员视角，含未发布内容）。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        rows = (
            db.query(LoginCarouselSlide)
            .order_by(LoginCarouselSlide.sort_order.asc(), LoginCarouselSlide.id.asc())
            .all()
        )
        return {"total": len(rows), "items": [_login_slide_to_dict(row) for row in rows]}


@router.post("/login-slides", status_code=status.HTTP_201_CREATED)
def admin_login_slides_create(
    payload: AdminLoginSlideCreatePayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """新建登录页轮播图。"""
    ensure_admin_tables()
    image_data, image_mime = _decode_admin_image(payload.image_data, payload.image_mime)
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        _validate_login_slide_publication(db, payload.published, False)
        last_slide = (
            db.query(LoginCarouselSlide)
            .order_by(LoginCarouselSlide.sort_order.desc(), LoginCarouselSlide.id.desc())
            .first()
        )
        sort_order = 0 if last_slide is None else last_slide.sort_order + 1
        row = LoginCarouselSlide(
            title=payload.title,
            description=payload.description,
            image_data=image_data,
            image_mime=image_mime,
            sort_order=sort_order,
            published=payload.published,
        )
        db.add(row)
        db.flush()
        _log_audit(
            db,
            operator_id=operator_id,
            action="create_login_slide",
            target_type="login_carousel_slide",
            target_id=str(row.id),
            detail=payload.title,
        )
        db.commit()
        db.refresh(row)
        return _login_slide_to_dict(row)


@router.put("/login-slides/{slide_id}")
def admin_login_slides_update(
    slide_id: int,
    payload: AdminLoginSlideUpdatePayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """更新登录页轮播图。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(LoginCarouselSlide).filter(LoginCarouselSlide.id == slide_id).first()
        if row is None:
            raise HTTPException(status_code=404, detail="轮播图不存在")
        next_published = row.published if payload.published is None else payload.published
        _validate_login_slide_publication(db, next_published, row.published)
        if payload.title is not None:
            row.title = payload.title
        if "description" in payload.model_fields_set:
            row.description = payload.description
        if payload.image_data is not None:
            image_data, image_mime = _decode_admin_image(payload.image_data, payload.image_mime)
            row.image_data = image_data
            row.image_mime = image_mime
        if payload.published is not None:
            row.published = payload.published
        row.updated_at = datetime.now(UTC)
        _log_audit(
            db,
            operator_id=operator_id,
            action="update_login_slide",
            target_type="login_carousel_slide",
            target_id=str(row.id),
            detail=row.title,
        )
        db.commit()
        db.refresh(row)
        return _login_slide_to_dict(row)


@router.put("/login-slides/actions/order")
def admin_login_slides_order(
    payload: AdminLoginSlideOrderPayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """按传入顺序重排全部登录轮播图。"""
    ensure_admin_tables()
    if len(payload.ids) != len(set(payload.ids)):
        raise HTTPException(status_code=400, detail="轮播图排序包含重复 ID")
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        rows = db.query(LoginCarouselSlide).order_by(LoginCarouselSlide.id.asc()).all()
        row_ids = [row.id for row in rows]
        if set(payload.ids) != set(row_ids):
            raise HTTPException(status_code=400, detail="轮播图排序必须包含全部现有 ID")
        rows_by_id = {row.id: row for row in rows}
        for index, slide_id in enumerate(payload.ids):
            rows_by_id[slide_id].sort_order = index
            rows_by_id[slide_id].updated_at = datetime.now(UTC)
        _log_audit(
            db,
            operator_id=operator_id,
            action="reorder_login_slides",
            target_type="login_carousel_slide",
            detail=",".join(str(slide_id) for slide_id in payload.ids),
        )
        db.commit()
        ordered_rows = [rows_by_id[slide_id] for slide_id in payload.ids]
        return {"total": len(ordered_rows), "items": [_login_slide_to_dict(row) for row in ordered_rows]}


@router.delete("/login-slides/{slide_id}")
def admin_login_slides_delete(
    slide_id: int,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """删除登录页轮播图。"""
    ensure_admin_tables()
    operator_id = student_id_of(session)
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(LoginCarouselSlide).filter(LoginCarouselSlide.id == slide_id).first()
        if row is None:
            raise HTTPException(status_code=404, detail="轮播图不存在")
        title = row.title
        db.delete(row)
        _log_audit(
            db,
            operator_id=operator_id,
            action="delete_login_slide",
            target_type="login_carousel_slide",
            target_id=str(slide_id),
            detail=title,
        )
        db.commit()
    return {"ok": True, "id": slide_id}


@router.get("/login-slides/{slide_id}/image")
def admin_login_slide_image(
    slide_id: int,
    session: AppSession = Depends(require_admin),
) -> Response:
    """管理员预览登录页轮播图图片。"""
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(LoginCarouselSlide).filter(LoginCarouselSlide.id == slide_id).first()
        if row is None:
            raise HTTPException(status_code=404, detail="轮播图不存在")
        try:
            content = base64.b64decode(row.image_data, validate=True)
        except ValueError as exc:
            raise HTTPException(status_code=500, detail="轮播图数据损坏") from exc
    return Response(content=content, media_type=row.image_mime)


# ─── 公众号文章管理（同步通道：RSS > 微信公开合集，可插拔） ──────


@router.get("/wechat/status")
def wechat_status(
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """公众号同步通道配置与最近同步状态（RSS 源的 token 一律脱敏，不写入响应）。"""
    settings = get_settings()
    from app.wechat_service import _mask_url, active_channel, last_sync_at

    channel = active_channel()
    last = last_sync_at()
    return {
        "channel": channel,
        "configured": channel != "none",
        # 只回传脱敏后的 URL（query token 仅保留前 4/后 4 位），避免私人 token 泄露
        "rssUrl": _mask_url(settings.wechat_rss_url) if settings.wechat_rss_url else None,
        "albumUrl": settings.wechat_album_url or None,
        "syncIntervalHours": settings.wechat_sync_interval_hours,
        "lastSyncedAt": last.isoformat() if last else None,
        "lastError": None,
    }


@router.post("/wechat/sync")
def wechat_sync_now(
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """立即同步公众号文章（管理员手动触发）。"""
    from app.wechat_service import sync_articles

    result = sync_articles()
    operator_id = student_id_of(session)
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        _log_audit(
            db,
            operator_id=operator_id,
            action="wechat_sync",
            target_type="wechat",
            target_id=None,
            detail=f"added={result['added']} error={result.get('error') or 'none'}",
        )
        db.commit()
    return result


@router.get("/wechat/articles")
def wechat_articles_list(
    session: AppSession = Depends(require_admin),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> dict[str, Any]:
    """公众号文章列表（管理员视角，含隐藏）。"""
    return wechat_service.list_articles(limit=limit, offset=offset)


@router.post("/wechat/articles/{article_id}/hide")
def wechat_article_hide(
    article_id: int,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """隐藏/取消隐藏公众号文章。"""
    if not wechat_service.set_hidden(article_id, True):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="文章不存在")
    operator_id = student_id_of(session)
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        _log_audit(
            db,
            operator_id=operator_id,
            action="wechat_hide",
            target_type="wechat_article",
            target_id=str(article_id),
        )
        db.commit()
    return {"ok": True, "id": article_id}


@router.post("/wechat/articles/{article_id}/unhide")
def wechat_article_unhide(
    article_id: int,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """取消隐藏公众号文章。"""
    if not wechat_service.set_hidden(article_id, False):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="文章不存在")
    return {"ok": True, "id": article_id}


@router.delete("/wechat/articles/{article_id}")
def wechat_article_delete(
    article_id: int,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """删除公众号文章。"""
    if not wechat_service.delete_article(article_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="文章不存在")
    operator_id = student_id_of(session)
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        _log_audit(
            db,
            operator_id=operator_id,
            action="wechat_delete",
            target_type="wechat_article",
            target_id=str(article_id),
        )
        db.commit()
    return {"ok": True, "id": article_id}


class WechatPasteImportPayload(BaseModel):
    url: str = Field(min_length=1, max_length=1000)


@router.post("/wechat/import")
def wechat_import_by_url(
    payload: WechatPasteImportPayload,
    request: Request,
    session: AppSession = Depends(require_admin),
) -> dict[str, Any]:
    """粘贴公众号文章链接导入（抓取公开元数据：og:title / og:image / msg_desc）。"""
    try:
        article = wechat_service.fetch_article_meta(payload.url)
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"解析失败: {exc}")
    added = wechat_service.upsert_articles([article], source="paste")
    operator_id = student_id_of(session)
    ensure_admin_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        _log_audit(
            db,
            operator_id=operator_id,
            action="wechat_import",
            target_type="wechat_article",
            target_id=None,
            detail=article.title[:200],
        )
        db.commit()
    return {"ok": True, "added": added, "title": article.title}
