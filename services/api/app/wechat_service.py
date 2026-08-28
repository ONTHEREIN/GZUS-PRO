"""公众号文章同步服务。

数据源（可插拔通道，按配置优先级选择）：
1. wechatrss 第三方 RSS 服务（配置 WECHAT_RSS_URL 后启用，含订阅 token）：
   在 wechatrss 账号里订阅公众号后，RSS 源自动输出文章（标题/简介/封面/时间/链接）。
2. 微信「合集/专辑」公开接口（appmsgalbum，配置 WECHAT_ALBUM_URL 后启用）：
   匿名、无需凭据，读取公开合集数据；需学校公众号建有合集。

架构：WechatFetcher 为可插拔抽象；default_fetcher() 按配置选通道。
新增通道只需实现 WechatFetcher，不动业务代码与路由。
注意：WECHAT_RSS_URL 含私人 token，任何日志/响应中都必须脱敏。
"""
from __future__ import annotations

import html as html_mod
import logging
import re
import xml.etree.ElementTree as ET
from datetime import UTC, datetime, timedelta
from email.utils import parsedate_to_datetime
from typing import Protocol
from urllib.parse import parse_qs, urlparse

import httpx

from app.config import get_settings
from app.database import (
    Base,
    WechatSyncState,
    WxArticle,
    get_sync_engine,
    get_sync_session_factory,
)

logger = logging.getLogger(__name__)

# 合集接口返回的封面图：wx_fmt=jpeg 原图，去掉 /0 缩放后缀后可取高清图
_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49"
)
_ALBUM_API = "https://mp.weixin.qq.com/mp/appmsgalbum"
_TIMEOUT = httpx.Timeout(15.0, connect=5.0)
_PAGE_SIZE = 20
_MAX_PAGES = 20  # 单次同步最多翻页数（防失控）

# 惰性同步兜底：上次同步距今超过间隔才在读取通知时后台触发
_table_ready = False


def _ensure_tables() -> None:
    """兼容旧数据库中尚未创建的公众号数据表。"""
    global _table_ready
    if _table_ready:
        return
    engine = get_sync_engine()
    Base.metadata.create_all(engine, tables=[WxArticle.__table__, WechatSyncState.__table__])
    _table_ready = True


# ─── 配置解析 ───────────────────────────────────────────────

def _parse_album_config(url: str) -> dict | None:
    """从合集链接解析 __biz 与 album_id。

    合集链接形如：
      https://mp.weixin.qq.com/mp/appmsgalbum?__biz=xxx&action=getalbum&album_id=123...
    """
    if not url:
        return None
    parsed = urlparse(url)
    if parsed.netloc not in ("mp.weixin.qq.com", "weixin.qq.com"):
        return None
    query = parse_qs(parsed.query)
    biz = (query.get("__biz") or [None])[0]
    album_id = (query.get("album_id") or [None])[0]
    if not biz or not album_id:
        # 兼容不带协议/带 #rd 片段的链接
        m = re.search(r"album_id=(\d+)", url)
        if m:
            album_id = m.group(1)
        m2 = re.search(r"__biz=([A-Za-z0-9=]+)", url)
        if m2:
            biz = m2.group(1)
    if not biz or not album_id:
        return None
    return {"biz": biz, "album_id": album_id}


# ─── 抓取器抽象 ─────────────────────────────────────────────

class WechatArticle:
    """归一化的公众号文章条目（与微信公开接口字段无关）。"""

    __slots__ = ("article_url", "author", "cover_url", "publish_time", "summary", "title")

    def __init__(self, title: str, summary: str | None, cover_url: str | None,
                 article_url: str, author: str | None = None, publish_time: str | None = None):
        self.title = (title or "").strip()
        self.summary = (summary or "").strip() or None
        self.cover_url = cover_url
        self.article_url = article_url
        self.author = author
        self.publish_time = publish_time


class WechatFetcher(Protocol):
    """公众号文章抓取通道抽象：返回 WechatArticle 列表。"""

    def fetch_latest(self, limit: int = 50) -> list[WechatArticle]:
        ...


class AlbumFetcher:
    """微信公开「合集」接口抓取器（匿名，无需凭据）。"""

    def __init__(self, album_url: str | None = None):
        self.config = _parse_album_config(album_url or get_settings().wechat_album_url)

    @property
    def enabled(self) -> bool:
        return self.config is not None

    def fetch_latest(self, limit: int = 50) -> list[WechatArticle]:
        if not self.enabled:
            return []
        cfg = self.config
        page = 0
        begin_msgid = 0
        begin_itemidx = 0
        collected: list[WechatArticle] = []
        with httpx.Client(timeout=_TIMEOUT, headers={"User-Agent": _UA}) as client:
            while page < _MAX_PAGES and len(collected) < limit:
                params = {
                    "action": "getalbum",
                    "__biz": cfg["biz"],
                    "album_id": cfg["album_id"],
                    "count": _PAGE_SIZE,
                    "begin_msgid": begin_msgid,
                    "begin_itemidx": begin_itemidx,
                    "f": "json",
                }
                try:
                    resp = client.get(_ALBUM_API, params=params)
                    resp.raise_for_status()
                    data = resp.json()
                except Exception as exc:
                    logger.warning("wechat album fetch failed (page=%d): %s", page, exc)
                    break
                base = data.get("base_resp", {}) or {}
                if base.get("ret") != 0:
                    logger.warning("wechat album ret=%s: %s", base.get("ret"), base.get("err_msg"))
                    break
                album = data.get("getalbum_resp", {}) or {}
                article_list = album.get("article_list") or []
                if not article_list:
                    break
                for item in article_list:
                    if len(collected) >= limit:
                        break
                    url = (item.get("url") or "").strip()
                    if not url:
                        continue
                    collected.append(
                        WechatArticle(
                            title=item.get("title") or "",
                            summary=None,
                            cover_url=_cover_url_of(item),
                            article_url=url,
                            author=None,
                            publish_time=_ts_to_date(item.get("create_time")),
                        )
                    )
                if not album.get("continue_flag"):
                    break
                # 翻页游标：取本页最后一条的 msgid/itemidx
                last = article_list[-1]
                begin_msgid = last.get("msgid") or begin_msgid
                begin_itemidx = last.get("itemidx") or begin_itemidx
                page += 1
        return collected


def _cover_url_of(item: dict) -> str | None:
    cover = item.get("cover_img_1_1") or ""
    if not cover:
        return None
    # mmbiz 图床：去掉 /0 后缀拿原图
    return re.sub(r"/0$", "", cover.strip()) or None


def _ts_to_date(value) -> str | None:
    try:
        ts = int(value)
    except (TypeError, ValueError):
        return None
    if ts <= 0:
        return None
    return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m-%d")


# ─── RSS 通道（wechatrss 第三方服务） ────────────────────────

_IMG_RE = re.compile(r'<img[^>]+src=["\']([^"\']+)["\']', re.IGNORECASE)


def _rss_description_cover(description: str | None) -> str | None:
    """从 RSS description 的 HTML 中提取第一张图作为封面。"""
    if not description:
        return None
    m = _IMG_RE.search(description)
    if not m:
        return None
    url = html_mod.unescape(m.group(1)).strip()
    return url or None


def _rss_description_text(description: str | None) -> str | None:
    """把 RSS description 剥成纯文本（作为简介，且兼容非 HTML 纯文本源）。"""
    if not description:
        return None
    # 无 < 标签时原样返回
    if "<" not in description:
        return description.strip() or None
    text = re.sub(r"<br\s*/?>|</p>|</div>", "\n", description, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = html_mod.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or None


def _rss_date_to_str(value: str | None) -> str | None:
    """把 RSS pubDate（RFC 822，如 Fri, 14 Aug 2026 17:01:46 +0000）转成 yyyy-MM-dd。"""
    if not value:
        return None
    try:
        dt = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    return dt.astimezone(UTC).strftime("%Y-%m-%d")


def _rss_item_text(item, tag: str) -> str | None:
    """RSS item 中指定子标签的文本（无则 None）。"""
    node = item.find(tag)
    return node.text.strip() if node is not None and node.text else None


class RssFetcher:
    """wechatrss 第三方 RSS 服务抓取器（标准库解析，无需新依赖）。"""

    def __init__(self, rss_url: str | None = None):
        self.rss_url = (rss_url or get_settings().wechat_rss_url).strip()

    @property
    def enabled(self) -> bool:
        return bool(self.rss_url)

    def fetch_latest(self, limit: int = 50) -> list[WechatArticle]:
        if not self.enabled:
            return []
        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            "Accept": "application/rss+xml, application/xml, text/xml, */*",
        }
        collected: list[WechatArticle] = []
        with httpx.Client(timeout=_TIMEOUT, headers=headers, follow_redirects=True) as client:
            resp = client.get(self.rss_url)
            resp.raise_for_status()
            root = ET.fromstring(resp.text)
        # RSS 2.0: channel/item；兼容 <rss><channel> 直接结构
        channel = root.find("channel")
        items = channel.findall("item") if channel is not None else root.findall("item")
        for item in items:
            if len(collected) >= limit:
                break
            # content:encoded 命名空间（正文，仅用于取封面图兜底）
            desc = _rss_item_text(item, "description") or ""
            content_node = item.find("{http://purl.org/rss/1.0/modules/content/}encoded")
            content = content_node.text if content_node is not None and content_node.text else ""
            title = _rss_item_text(item, "title")
            link = _rss_item_text(item, "link")
            if not title or not link:
                continue
            cover = _rss_description_cover(desc) or _rss_description_cover(content)
            summary = _rss_description_text(desc)
            collected.append(
                WechatArticle(
                    title=title,
                    summary=summary,
                    cover_url=cover,
                    article_url=link,
                    author=_rss_item_text(item, "author"),
                    publish_time=_rss_date_to_str(_rss_item_text(item, "pubDate")),
                )
            )
        return collected


def _mask_url(url: str | None) -> str | None:
    """脱敏 URL 中的 token（query 参数）：只保留参数名与值的前 4/后 4 位。"""
    if not url:
        return None
    parsed = urlparse(url)
    if not parsed.query:
        return url
    parts = []
    for kv in parsed.query.split("&"):
        if "=" not in kv:
            parts.append(kv)
            continue
        key, _, value = kv.partition("=")
        if value and len(value) > 12:
            value = f"{value[:4]}…{value[-4:]}"
        parts.append(f"{key}={value}")
    return f"{parsed._replace(query='&'.join(parts)).geturl()}"


def default_fetcher() -> WechatFetcher:
    """按配置优先级选择同步通道：RSS > 合集。"""
    settings = get_settings()
    if settings.wechat_rss_url.strip():
        return RssFetcher()
    return AlbumFetcher()


def active_channel() -> str:
    """当前生效的通道名：rss / album / none（供管理后台展示）。"""
    settings = get_settings()
    if settings.wechat_rss_url.strip():
        return "rss"
    if _parse_album_config(settings.wechat_album_url):
        return "album"
    return "none"


def fetch_article_meta(url: str) -> WechatArticle:
    """从单篇公众号文章链接抓取公开元数据（og:title / og:image / msg_desc）。

    用于管理员「粘贴链接导入」兜底：读取的是网页公开元数据，合法且无需凭据。
    """
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept-Language": "zh-CN,zh;q=0.9",
    }
    with httpx.Client(timeout=_TIMEOUT, headers=headers, follow_redirects=True) as client:
        resp = client.get(url)
        resp.raise_for_status()
        text = resp.text

    def _meta(prop: str) -> str | None:
        m = re.search(
            rf'<meta[^>]+(?:property|name)=["\']{re.escape(prop)}["\'][^>]*content=["\']([^"\']+)["\']',
            text,
            re.IGNORECASE,
        )
        if m:
            return html_mod.unescape(m.group(1)).strip()
        m = re.search(
            rf'<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name)=["\']{re.escape(prop)}["\']',
            text,
            re.IGNORECASE,
        )
        if m:
            return html_mod.unescape(m.group(1)).strip()
        return None

    title = _meta("og:title") or _meta("twitter:title")
    cover = _meta("og:image") or _meta("twitter:image")
    summary = _meta("og:description") or _meta("description")
    if not summary:
        m = re.search(r'var msg_desc\s*=\s*"([^"]*)"', text)
        if m:
            summary = html_mod.unescape(m.group(1)).strip()
    if not title:
        m = re.search(r"<title>([^<]*)</title>", text, re.IGNORECASE)
        if m:
            title = html_mod.unescape(m.group(1)).strip()
    if not title:
        raise ValueError("无法从链接中解析出标题")
    return WechatArticle(title=title, summary=summary or None, cover_url=cover or None, article_url=url)


# ─── 存储与同步 ─────────────────────────────────────────────

def _row_to_notice(row: WxArticle) -> dict:
    """WxArticle 行 → 通知条目（category=公众号，带封面）。"""
    return {
        "category": "公众号",
        "title": row.title,
        "date": row.publish_time,
        "url": row.article_url,
        "summary": row.summary,
        "coverUrl": row.cover_url,
        "source": "wechat",
    }


def list_visible_articles(limit: int = 50) -> list[dict]:
    """未隐藏的公众号文章（按发布时间倒序，无时间的排末尾）。"""
    _ensure_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        rows = db.query(WxArticle).filter(WxArticle.hidden.is_(False)).all()
        rows.sort(
            key=lambda r: (r.publish_time or "", r.id),
            reverse=True,
        )
        return [_row_to_notice(r) for r in rows[:limit]]


def list_articles(limit: int = 200, offset: int = 0) -> dict:
    """管理员视角：全部文章（含隐藏），按入库倒序。"""
    _ensure_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        total = db.query(WxArticle).count()
        rows = (
            db.query(WxArticle)
            .order_by(WxArticle.id.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        items = [
            {
                "id": row.id,
                "title": row.title,
                "summary": row.summary,
                "coverUrl": row.cover_url,
                "articleUrl": row.article_url,
                "author": row.author,
                "publishTime": row.publish_time,
                "source": row.source,
                "hidden": row.hidden,
                "createdAt": row.created_at.isoformat() if row.created_at else None,
            }
            for row in rows
        ]
    return {"total": total, "items": items}


def set_hidden(article_id: int, hidden: bool) -> bool:
    _ensure_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WxArticle).filter(WxArticle.id == article_id).first()
        if row is None:
            return False
        row.hidden = hidden
        row.updated_at = datetime.now(UTC)
        db.commit()
        return True


def delete_article(article_id: int) -> bool:
    _ensure_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WxArticle).filter(WxArticle.id == article_id).first()
        if row is None:
            return False
        db.delete(row)
        db.commit()
        return True


def upsert_articles(articles: list[WechatArticle], source: str = "album") -> int:
    """按 article_url upsert，返回新增条数。"""
    _ensure_tables()
    if not articles:
        return 0
    factory = get_sync_session_factory()
    added = 0
    with factory() as db:
        for art in articles:
            url = art.article_url
            if not url:
                continue
            exists = db.query(WxArticle).filter(WxArticle.article_url == url).first()
            if exists is None:
                db.add(
                    WxArticle(
                        title=art.title,
                        summary=art.summary,
                        cover_url=art.cover_url,
                        article_url=url,
                        author=art.author,
                        publish_time=art.publish_time,
                        source=source,
                    )
                )
                added += 1
            else:
                # 已有条目：仅补齐空字段（标题/封面可能后来才有）
                changed = False
                if art.title and not exists.title:
                    exists.title = art.title
                    changed = True
                if art.summary and not exists.summary:
                    exists.summary = art.summary
                    changed = True
                if art.cover_url and not exists.cover_url:
                    exists.cover_url = art.cover_url
                    changed = True
                if art.publish_time and not exists.publish_time:
                    exists.publish_time = art.publish_time
                    changed = True
                if changed:
                    exists.updated_at = datetime.now(UTC)
        db.commit()
    if added:
        logger.info("wechat sync: added %d new articles", added)
    return added


def sync_articles(fetcher: WechatFetcher | None = None, limit: int = 50) -> dict:
    """执行一次同步并记录状态；返回 {added, total, lastSyncedAt}。"""
    _ensure_tables()
    fetcher = fetcher or default_fetcher()
    now = datetime.now(UTC)
    result = {"added": 0, "total": 0, "lastSyncedAt": None, "error": None}
    try:
        articles = fetcher.fetch_latest(limit=limit)
        result["added"] = upsert_articles(articles)
        result["total"] = articles and len(articles) or 0
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(WechatSyncState).filter(WechatSyncState.key == "album").first()
            if row is None:
                row = WechatSyncState(key="album")
                db.add(row)
            row.last_synced_at = now
            row.last_error = None
            row.updated_at = now
            db.commit()
        result["lastSyncedAt"] = now.isoformat()
    except Exception as exc:
        logger.warning("wechat sync failed: %s", exc, exc_info=True)
        result["error"] = str(exc)
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(WechatSyncState).filter(WechatSyncState.key == "album").first()
            if row is None:
                row = WechatSyncState(key="album")
                db.add(row)
            row.last_error = str(exc)[:500]
            row.updated_at = now
            db.commit()
    return result


def last_sync_at() -> datetime | None:
    _ensure_tables()
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WechatSyncState).filter(WechatSyncState.key == "album").first()
        return row.last_synced_at if row else None


def should_sync() -> bool:
    """是否需要惰性同步：未配置任何通道→False；从未同步→True；超过间隔→True。"""
    if active_channel() == "none":
        return False
    last = last_sync_at()
    if last is None:
        return True
    # SQLite 读出的 naive 时间按 UTC 归一化（与 cache_service._is_stale 同约定）
    if last.tzinfo is None:
        last = last.replace(tzinfo=UTC)
    interval = timedelta(hours=get_settings().wechat_sync_interval_hours)
    return datetime.now(UTC) - last > interval


def trigger_lazy_sync() -> None:
    """惰性同步：后台线程执行一次同步，不阻塞请求。"""
    if not should_sync():
        return
    import threading

    def _run():
        try:
            sync_articles()
        except Exception:
            logger.exception("lazy wechat sync failed")

    threading.Thread(target=_run, daemon=True).start()
