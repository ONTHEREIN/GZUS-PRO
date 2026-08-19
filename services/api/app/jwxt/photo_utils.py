"""JWXT 学生照片/图片处理辅助（自 school_client.py 拆分）。

包含：图片 MIME 嗅探、任意图片→PNG 归一化、编码照片 URL 提取、
以及按前缀生成教务系统端点 URL 的辅助。
"""
import logging
import re

logger = logging.getLogger(__name__)


def _detect_image_mime(data: bytes) -> str | None:
    if len(data) < 4:
        return None
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:2] == b"BM":
        return "image/bmp"
    if data[:4] == b"RIFF" and len(data) >= 12 and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def _normalize_image_to_png(data: bytes, content_type: str) -> tuple[bytes | None, str]:
    try:
        from io import BytesIO

        from PIL import Image

        img = Image.open(BytesIO(data))
        img.load()
        if img.mode in ("RGBA", "LA", "PA"):
            background = Image.new("RGBA", img.size, (255, 255, 255, 255))
            background.paste(img, mask=img.split()[-1])
            img = background.convert("RGB")
        elif img.mode != "RGB":
            img = img.convert("RGB")
        buf = BytesIO()
        img.save(buf, format="PNG", optimize=True)
        logger.debug("_normalize_image_to_png: converted %s -> PNG, %d -> %d bytes", content_type, len(data), buf.tell())
        return buf.getvalue(), "image/png"
    except Exception as exc:
        logger.warning("_normalize_image_to_png: failed to convert: %s", exc)
        return None, content_type


_ENCODED_PHOTO_PATTERN = re.compile(
    r'(?:src|href)=["\']([^"\']*photo_cxEncodedXszp[^"\']*zplx=rxhzp[^"\']*)["\']',
    re.IGNORECASE,
)


def _extract_encoded_photo_url(html: str) -> str | None:
    """Extract the encoded photo URL from the student info HTML page."""
    match = _ENCODED_PHOTO_PATTERN.search(html)
    if match:
        url = match.group(1)
        # Unescape HTML entities
        url = url.replace("&amp;", "&")
        return url
    return None


def prefixed_url_endpoints(prefix: str) -> dict:
    return {
        "HOME_URL": f"{prefix}/xtgl/login_slogin.html",
        "INDEX_URL": f"{prefix}/xtgl/index_initMenu.html",
        "LOGIN": {
            "INDEX": f"{prefix}/xtgl/login_slogin.html",
            "CAPTCHA": f"{prefix}/zfcaptchaLogin",
            "KCAPTCHA": f"{prefix}/kaptcha",
            "PUBLIC_KEY": f"{prefix}/xtgl/login_getPublicKey.html",
        },
        "SCORE_URL": "",
        "INFO_URL": "",
        "SCHEDULE": {"API": f"{prefix}/kbcx/xskbcx_cxXsKb.html"},
        "CLASS_SCHEDULE": {"API": f"{prefix}/kbdy/bjkbdy_cxBjKb.html"},
        "SCORE": {"API": f"{prefix}/cjcx/cjcx_cxDgXscj.html"},
        "INFO": {"API": f"{prefix}/xsxxxggl/xsgrxxwh_cxXsgrxx.html"},
    }
