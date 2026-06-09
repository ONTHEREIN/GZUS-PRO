from __future__ import annotations

import re

_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\ufffd]")
_READABLE_RE = re.compile(r"[A-Za-z0-9\u4e00-\u9fff]")
_BROKEN_ENCODING_RE = re.compile(r"[\u0080-\u009f\ufffd]")
_MOJIBAKE_LETTER_RE = re.compile(r"[ÃÂÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ]")
_MOJIBAKE_MARK_RE = re.compile(r"[€œžŸ¢£¥§¨©ª«¬®¯°±²³´µ¶·¸¹º»¼½¾¿–—]")


def clean_notice_text(value: object) -> str:
    text = str(value or "").strip()
    text = _CONTROL_RE.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


def looks_garbled(value: object) -> bool:
    text = str(value or "")
    if _BROKEN_ENCODING_RE.search(text):
        return True
    if _READABLE_RE.search(text) and re.search(r"[\u4e00-\u9fff]", text):
        return False
    return bool(_MOJIBAKE_LETTER_RE.search(text) and _MOJIBAKE_MARK_RE.search(text))


def normalize_notice_item(item: dict) -> dict:
    normalized = dict(item)
    for key in ("category", "title", "summary", "date"):
        if key in normalized:
            normalized[key] = clean_notice_text(normalized.get(key))
    return normalized


def is_valid_notice_item(item: dict) -> bool:
    title = clean_notice_text(item.get("title"))
    summary = clean_notice_text(item.get("summary"))
    category = clean_notice_text(item.get("category"))
    candidate = title or summary
    if not candidate:
        return False
    if looks_garbled(title) or looks_garbled(summary) or looks_garbled(category):
        return False
    return bool(_READABLE_RE.search(candidate))


def valid_notice_items(items: list[dict]) -> list[dict]:
    return [
        normalized
        for normalized in (normalize_notice_item(item) for item in items)
        if is_valid_notice_item(normalized)
    ]
