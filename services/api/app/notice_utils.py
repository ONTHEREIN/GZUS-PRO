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
    normalized["source"] = str(normalized.get("source") or "jwxt")
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


def notice_key(item: dict) -> str:
    """通知去重键：类别|标题|链接。"""
    title = str(item.get("title") or "").strip()
    url = str(item.get("url") or "").strip()
    category = str(item.get("category") or "").strip()
    return "|".join([category, title, url])


def merge_notices(jwxt_items: list[dict], ehall_items: list[dict]) -> list[dict]:
    """合并 JWXT 与 ehall 通知：ehall 条目归一化后按去重键追加，整体过滤无效项。"""
    items = list(jwxt_items)
    seen = {notice_key(item) for item in items}
    for item in ehall_items:
        normalized = normalize_notice_item(item)
        key = notice_key(normalized)
        if is_valid_notice_item(normalized) and key not in seen:
            seen.add(key)
            items.append(normalized)
    return valid_notice_items(items)
