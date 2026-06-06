from __future__ import annotations

import logging

import ddddocr

logger = logging.getLogger(__name__)


class CaptchaOcr:
    """Wrapper around ddddocr for CAPTCHA image recognition."""

    def __init__(self) -> None:
        self._ocr: ddddocr.DdddOcr | None = None

    @property
    def ocr(self) -> ddddocr.DdddOcr:
        if self._ocr is None:
            self._ocr = ddddocr.DdddOcr(show_ad=False)
        return self._ocr

    def recognize(self, image_bytes: bytes) -> str:
        try:
            return self.ocr.classification(image_bytes)
        except Exception:
            logger.warning("Captcha OCR recognition failed", exc_info=True)
            return ""


captcha_ocr = CaptchaOcr()
