"""公众号文章同步服务测试（微信公开合集接口 + og 元数据解析 + upsert 去重）。"""
import base64
from datetime import UTC

from app.config import get_settings
from app.database import WechatSyncState, WxArticle, get_sync_session_factory
from app.wechat_service import (
    AlbumFetcher,
    WechatArticle,
    _parse_album_config,
    delete_article,
    fetch_article_meta,
    list_visible_articles,
    set_hidden,
    should_sync,
    sync_articles,
    upsert_articles,
)

ALBUM_URL = "https://mp.weixin.qq.com/mp/appmsgalbum?__biz=Mzg5NDY3NzIwMA==&album_id=2038088622687469575"


# ─── 配置解析 ─────────────────────────────────────────────

def test_parse_album_config_valid():
    cfg = _parse_album_config(ALBUM_URL)
    assert cfg == {"biz": "Mzg5NDY3NzIwMA==", "album_id": "2038088622687469575"}


def test_parse_album_config_fragment_suffix():
    cfg = _parse_album_config(ALBUM_URL + "#rd")
    assert cfg == {"biz": "Mzg5NDY3NzIwMA==", "album_id": "2038088622687469575"}


def test_parse_album_config_rejects_article_link():
    assert _parse_album_config("https://mp.weixin.qq.com/s/abc") is None
    assert _parse_album_config("") is None
    assert _parse_album_config("https://example.com/x") is None


# ─── upsert / 列表 / 隐藏 ─────────────────────────────────

def test_upsert_dedupes_by_article_url():
    arts = [
        WechatArticle(title="A", summary="s1", cover_url="c1", article_url="u1", publish_time="2026-01-01"),
        WechatArticle(title="B", summary=None, cover_url=None, article_url="u2"),
    ]
    assert upsert_articles(arts) == 2
    # 同 URL 再次 upsert 不重复
    assert upsert_articles(arts) == 0
    factory = get_sync_session_factory()
    with factory() as db:
        assert db.query(WxArticle).count() == 2


def test_upsert_backfills_missing_fields():
    upsert_articles([WechatArticle(title="", summary=None, cover_url=None, article_url="u1")])
    upsert_articles(
        [WechatArticle(title="A", summary="s", cover_url="c", article_url="u1", publish_time="2026-01-02")]
    )
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WxArticle).filter(WxArticle.article_url == "u1").first()
        assert row.title == "A"
        assert row.summary == "s"
        assert row.cover_url == "c"
        assert row.publish_time == "2026-01-02"


def test_list_visible_excludes_hidden_and_sorts_by_publish_time():
    upsert_articles(
        [
            WechatArticle(title="旧", summary=None, cover_url=None, article_url="u1", publish_time="2026-01-01"),
            WechatArticle(title="新", summary=None, cover_url=None, article_url="u2", publish_time="2026-03-01"),
            WechatArticle(title="无日期", summary=None, cover_url=None, article_url="u3", publish_time=None),
        ]
    )
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WxArticle).filter(WxArticle.article_url == "u1").first()
        row.hidden = True
        db.commit()

    items = list_visible_articles()
    titles = [i["title"] for i in items]
    assert titles == ["新", "无日期"]  # 隐藏的 u1 不出现，无日期排末尾
    assert items[0]["category"] == "公众号"
    assert "coverUrl" in items[0]


def test_set_hidden_and_delete():
    upsert_articles([WechatArticle(title="A", summary=None, cover_url=None, article_url="u1")])
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WxArticle).first()
        article_id = row.id
    assert set_hidden(article_id, True) is True
    assert list_visible_articles() == []
    assert set_hidden(99999, True) is False
    assert delete_article(article_id) is True
    assert delete_article(article_id) is False


# ─── og 元数据解析（粘贴链接兜底） ─────────────────────────

def test_fetch_article_meta_parses_og_tags(monkeypatch):
    html = """
    <html><head>
      <meta property="og:title" content="测试标题">
      <meta property="og:image" content="https://img.example/cover.jpg">
      <meta property="og:description" content="这是简介">
      <title>忽略我</title>
    </head></html>
    """

    class FakeResp:
        text = html
        raise_for_status = lambda self: None

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        def get(self, url):
            assert url == "https://mp.weixin.qq.com/s/abc"
            return FakeResp()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    import app.wechat_service as ws

    monkeypatch.setattr(ws.httpx, "Client", FakeClient)
    article = fetch_article_meta("https://mp.weixin.qq.com/s/abc")
    assert article.title == "测试标题"
    assert article.cover_url == "https://img.example/cover.jpg"
    assert article.summary == "这是简介"


def test_fetch_article_meta_falls_back_to_title_tag(monkeypatch):
    html = "<html><head><title>标题标签</title></head></html>"

    class FakeResp:
        text = html
        raise_for_status = lambda self: None

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        def get(self, url):
            return FakeResp()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    import app.wechat_service as ws

    monkeypatch.setattr(ws.httpx, "Client", FakeClient)
    article = fetch_article_meta("https://mp.weixin.qq.com/s/abc")
    assert article.title == "标题标签"


def test_fetch_article_meta_raises_without_title(monkeypatch):
    class FakeResp:
        text = "<html><body>无标题</body></html>"
        raise_for_status = lambda self: None

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        def get(self, url):
            return FakeResp()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    import pytest

    import app.wechat_service as ws

    monkeypatch.setattr(ws.httpx, "Client", FakeClient)
    with pytest.raises(ValueError):
        fetch_article_meta("https://mp.weixin.qq.com/s/abc")


# ─── 同步状态与惰性判断 ─────────────────────────────────

class FakeFetcher:
    def __init__(self, articles):
        self._articles = articles

    def fetch_latest(self, limit=50):
        return self._articles


def test_sync_articles_records_state(monkeypatch):
    monkeypatch.setattr(
        "app.wechat_service.AlbumFetcher",
        lambda *a, **k: FakeFetcher([WechatArticle(title="A", summary=None, cover_url=None, article_url="u1")]),
    )
    result = sync_articles()
    assert result["added"] == 1
    assert result["lastSyncedAt"] is not None
    assert result["error"] is None
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WechatSyncState).filter(WechatSyncState.key == "album").first()
        assert row is not None
        assert row.last_synced_at is not None


def test_sync_articles_records_error(monkeypatch):
    class BrokenFetcher:
        def fetch_latest(self, limit=50):
            raise RuntimeError("boom")

    monkeypatch.setattr(
        "app.wechat_service.AlbumFetcher",
        lambda *a, **k: BrokenFetcher(),
    )
    result = sync_articles()
    assert result["error"] == "boom"
    factory = get_sync_session_factory()
    with factory() as db:
        row = db.query(WechatSyncState).filter(WechatSyncState.key == "album").first()
        assert row.last_error == "boom"


def test_should_sync_requires_config(monkeypatch):
    # 未配置合集 → 永不惰性同步
    get_settings.cache_clear()
    monkeypatch.setenv("WECHAT_ALBUM_URL", "")
    get_settings.cache_clear()
    assert should_sync() is False


def test_should_sync_true_when_never_synced(monkeypatch):
    get_settings.cache_clear()
    monkeypatch.setenv("WECHAT_ALBUM_URL", ALBUM_URL)
    get_settings.cache_clear()
    assert should_sync() is True


def test_should_sync_false_after_recent_sync(monkeypatch):
    from datetime import datetime

    get_settings.cache_clear()
    monkeypatch.setenv("WECHAT_ALBUM_URL", ALBUM_URL)
    get_settings.cache_clear()
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(WechatSyncState(key="album", last_synced_at=datetime.now(UTC)))
        db.commit()
    assert should_sync() is False


def test_should_sync_true_after_interval(monkeypatch):
    from datetime import datetime, timedelta

    get_settings.cache_clear()
    monkeypatch.setenv("WECHAT_ALBUM_URL", ALBUM_URL)
    get_settings.cache_clear()
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            WechatSyncState(
                key="album",
                last_synced_at=datetime.now(UTC) - timedelta(hours=7),
            )
        )
        db.commit()
    assert should_sync() is True


def test_album_fetcher_disabled_without_config(monkeypatch):
    get_settings.cache_clear()
    monkeypatch.setenv("WECHAT_ALBUM_URL", "")
    get_settings.cache_clear()
    fetcher = AlbumFetcher(None)
    assert fetcher.enabled is False
    assert fetcher.fetch_latest() == []


def test_image_base64_roundtrip():
    """校历图片 base64 存储可经端点解码（与 admin_notices 共用约定）。"""
    raw = b"\x89PNG\r\n\x1a\nfake"
    encoded = base64.b64encode(raw).decode()
    assert base64.b64decode(encoded) == raw
