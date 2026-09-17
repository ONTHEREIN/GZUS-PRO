from __future__ import annotations

import base64
import binascii
import json
import os
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status

from app.database import FeedbackTicket, get_sync_session_factory
from app.routes.deps import require_session
from app.schemas import FEEDBACK_ATTACHMENT_MAX_BYTES, FeedbackCreateRequest
from app.sessions import AppSession, student_id_of

router = APIRouter(prefix="/feedback", tags=["feedback"])


def _safe_attachment_name(name: str) -> str:
    """去掉客户端可能传来的目录，只保存文件名。"""
    normalized = name.replace("\\", "/")
    safe_name = os.path.basename(normalized).strip()
    if not safe_name or safe_name in {".", ".."}:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="附件文件名无效")
    return safe_name


def _decode_attachments(payload: FeedbackCreateRequest) -> list[dict[str, Any]]:
    total_bytes = 0
    attachments: list[dict[str, Any]] = []
    for item in payload.attachments:
        try:
            content = base64.b64decode(item.content_base64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"附件「{item.name}」不是有效的 base64 文件",
            ) from exc
        if not content:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"附件「{item.name}」内容为空",
            )
        total_bytes += len(content)
        if total_bytes > FEEDBACK_ATTACHMENT_MAX_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail="附件总大小不能超过 6 MB",
            )
        attachments.append(
            {
                "name": _safe_attachment_name(item.name),
                "mimeType": item.mime_type or "application/octet-stream",
                "size": len(content),
                "contentBase64": item.content_base64,
            }
        )
    return attachments


@router.post("", status_code=status.HTTP_201_CREATED)
def create_feedback(
    payload: FeedbackCreateRequest,
    session: AppSession = Depends(require_session),
) -> dict[str, Any]:
    """接收登录用户反馈，并将诊断日志与附件持久化给管理员查看。"""
    student_id = student_id_of(session)
    if not student_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="无法识别当前登录用户")
    if not payload.title.strip():
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="标题不能为空")
    if not payload.description.strip():
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="描述不能为空")

    attachments = _decode_attachments(payload)
    factory = get_sync_session_factory()
    with factory() as db:
        row = FeedbackTicket(
            student_id=student_id,
            student_name=session.student_name,
            category=payload.category,
            title=payload.title.strip(),
            description=payload.description.strip(),
            contact=payload.contact.strip() if payload.contact else None,
            client_logs=payload.client_logs,
            attachments_json=json.dumps(attachments, ensure_ascii=False, separators=(",", ":")),
            status="open",
        )
        db.add(row)
        db.commit()
        db.refresh(row)
        return {
            "id": row.id,
            "status": row.status,
            "createdAt": row.created_at,
        }
