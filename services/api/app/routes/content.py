"""无需登录即可读取的应用内容。"""

from __future__ import annotations

import base64

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from app.database import LoginCarouselSlide, get_sync_session_factory

router = APIRouter(prefix="/content", tags=["content"])

LOGIN_SLIDE_LIMIT = 5


def _slide_to_dict(row: LoginCarouselSlide) -> dict[str, object]:
    return {
        "id": row.id,
        "title": row.title,
        "description": row.description,
        "imageUrl": f"/content/login-slides/{row.id}/image",
    }


@router.get("/login-slides")
def list_login_slides() -> list[dict[str, object]]:
    """返回最多五张已发布的登录页轮播图。"""
    factory = get_sync_session_factory()
    with factory() as db:
        rows = (
            db.query(LoginCarouselSlide)
            .filter(LoginCarouselSlide.published.is_(True))
            .order_by(LoginCarouselSlide.sort_order.asc(), LoginCarouselSlide.id.asc())
            .limit(LOGIN_SLIDE_LIMIT)
            .all()
        )
        return [_slide_to_dict(row) for row in rows]


@router.get("/login-slides/{slide_id}/image")
def login_slide_image(slide_id: int) -> Response:
    """返回已发布登录页轮播图的原始图片。"""
    factory = get_sync_session_factory()
    with factory() as db:
        row = (
            db.query(LoginCarouselSlide)
            .filter(
                LoginCarouselSlide.id == slide_id,
                LoginCarouselSlide.published.is_(True),
            )
            .first()
        )
        if row is None:
            raise HTTPException(status_code=404, detail="轮播图不存在")
        try:
            content = base64.b64decode(row.image_data, validate=True)
        except ValueError as exc:
            raise HTTPException(status_code=500, detail="轮播图数据损坏") from exc
    return Response(content=content, media_type=row.image_mime)
