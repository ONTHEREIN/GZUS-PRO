from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


class CaptchaOcr:
    """Wrapper around ddddocr for CAPTCHA image recognition.

    ddddocr is imported lazily so the server can start without it installed.
    OCR will fail gracefully with a clear error if the package is missing.
    """

    def __init__(self) -> None:
        self._ocr = None

    def _ensure_ocr(self):
        if self._ocr is not None:
            return
        try:
            import ddddocr

            self._ocr = ddddocr.DdddOcr(show_ad=False)
        except ModuleNotFoundError:
            raise RuntimeError(
                "ddddocr 未安装，无法进行验证码识别。"
                "请运行: pip install ddddocr"
            )

    def recognize(self, image_bytes: bytes) -> str:
        try:
            self._ensure_ocr()
            return self._ocr.classification(image_bytes)
        except RuntimeError:
            raise
        except Exception:
            logger.warning("Captcha OCR recognition failed", exc_info=True)
            return ""


captcha_ocr = CaptchaOcr()
