"""JWXT 通知页 HTML 解析：自研轻量 HTML 节点 + 通知条目/详情提取。

从 school_client.py 拆出，仅依赖标准库（dataclasses/html.parser/re）。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin

# 通知标题前缀（如【教务】、日期前缀）——从 school_client.py 迁入
NOTICE_PREFIX_PATTERNS = [re.compile(p) for p in [r'【[^】]*】', r'\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?']]
DATE_PATTERN = re.compile(r'\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?')
HTML_URL_PATTERN = re.compile(r"['\"]([^'\"]+\.html(?:\?[^'\"]*)?)['\"]")
_NON_NOTICE_TITLES = {
    "更多",
    "通知公告",
    "当前角色消息",
    "其他角色消息",
    "待阅事宜",
    "已阅事宜",
    "名称",
    "待办事宜",
    "已办事宜",
}

@dataclass
class HtmlNode:
    tag: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list[Any] = field(default_factory=list)
    parent: "HtmlNode | None" = field(default=None, repr=False)

class SimpleHtmlParser(HTMLParser):
    void_tags = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = HtmlNode("root")
        self._stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        node = HtmlNode(tag.lower(), {key.lower(): value or "" for key, value in attrs})
        node.parent = self._stack[-1]
        self._stack[-1].children.append(node)
        if node.tag not in self.void_tags:
            self._stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if self._stack[-1].tag == tag.lower():
            self._stack.pop()

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        while len(self._stack) > 1:
            node = self._stack.pop()
            if node.tag == tag:
                break

    def handle_data(self, data: str) -> None:
        if data:
            self._stack[-1].children.append(data)

def extract_notice_sections(html: str, page_url: str) -> list[dict]:
    root = parse_html(html)
    sections = []
    for node in iter_nodes(root):
        if node.tag not in {"div", "section", "article", "ul"}:
            continue
        node_class = node.attrs.get("class", "")
        is_panel_widget = node.tag == "div" and ("panel" in node_class or "widget-box" in node_class)
        if not is_notice_section(node) and not is_panel_widget:
            continue
        if any(
            ancestor.tag in {"div", "section", "article", "ul"} and is_notice_section(ancestor)
            for ancestor in ancestors(node)
        ):
            continue
        category = strip_notice_prefixes(section_title(node) or "") or "通知"
        items = extract_notice_items_from_node(node, page_url, category)
        if items:
            section = {"category": category, "items": items}
            more_url = extract_more_url(node)
            if more_url:
                section["moreUrl"] = more_url
            sections.append(section)
    if not sections:
        items = extract_notice_items(html, page_url, "通知")
        if items:
            sections.append({"category": "通知", "items": items})
    return sections

def extract_notice_items(html: str, page_url: str, category: str = "通知") -> list[dict]:
    return extract_notice_items_from_node(parse_html(html), page_url, category)

def extract_notice_detail(html: str, page_url: str) -> dict:
    root = parse_html(html)
    title = ""
    date = None
    content_html = ""
    for node in iter_nodes(root):
        if node.tag in {"h1", "h2"}:
            candidate = clean_text(text_content(node))
            if candidate and not title:
                title = candidate
        if node.tag in {"div", "span"}:
            cls = node.attrs.get("class", "")
            if "article-title" in cls or "news-title" in cls:
                candidate = clean_text(text_content(node))
                if candidate and not title:
                    title = candidate
            if "date" in cls.split() or "time" in cls.split() or "article-date" in cls or "news-date" in cls:
                candidate = clean_text(text_content(node))
                if candidate and not date:
                    date = extract_date(candidate)
    content_node = _find_notice_content_node(root)
    if content_node is not None:
        content_html = _inner_html(content_node)
    if not title:
        for node in iter_nodes(root):
            if node.tag in {"h3", "h4", "h5"}:
                candidate = clean_text(text_content(node))
                if candidate:
                    title = candidate
                    break
    if not date:
        for node in iter_nodes(root):
            if node.tag == "span":
                cls = node.attrs.get("class", "")
                if "date" in cls or "time" in cls:
                    candidate = clean_text(text_content(node))
                    extracted = extract_date(candidate)
                    if extracted:
                        date = extracted
                        break
    return {"title": title, "date": date, "contentHtml": content_html, "url": page_url}

def _find_notice_content_node(root: HtmlNode) -> HtmlNode | None:
    content_selectors = [
        lambda n: n.tag == "div" and any(
            c in n.attrs.get("class", "")
            for c in ("article-content", "news-content", "article_content", "news_content", "content-box", "detail-content", "detail_content")
        ),
        lambda n: n.tag == "div" and n.attrs.get("id") in ("content", "article", "articleContent", "newsContent", "ContentBody"),
        lambda n: n.tag == "div" and "container" in n.attrs.get("class", "") and _has_article_like_structure(n),
    ]
    for selector in content_selectors:
        for node in iter_nodes(root):
            if selector(node):
                return node
    return _find_largest_text_block(root)

def _has_article_like_structure(node: HtmlNode) -> bool:
    text_len = len(text_content(node))
    if text_len < 50:
        return False
    child_tags = set()
    for child in iter_nodes(node):
        if isinstance(child, HtmlNode) and child.tag in {"p", "br", "img", "table", "ul", "ol"}:
            child_tags.add(child.tag)
    return len(child_tags) >= 1 or text_len > 200

def _find_largest_text_block(root: HtmlNode) -> HtmlNode | None:
    best_node = None
    best_len = 0
    for node in iter_nodes(root):
        if node.tag not in {"div", "article", "section", "td"}:
            continue
        text = text_content(node)
        text_len = len(text.strip())
        if text_len > best_len:
            best_len = text_len
            best_node = node
    return best_node

def _inner_html(node: HtmlNode) -> str:
    parts: list[str] = []
    for child in node.children:
        parts.append(_render_node(child))
    return "".join(parts)

def _render_node(node) -> str:
    if isinstance(node, str):
        return _escape_html(node)
    if not isinstance(node, HtmlNode):
        return ""
    if node.tag in {"script", "style"}:
        return ""
    attrs_str = ""
    for key, value in node.attrs.items():
        attrs_str += f' {key}="{_escape_html(value)}"'
    void_tags = SimpleHtmlParser.void_tags
    if node.tag in void_tags:
        return f"<{node.tag}{attrs_str}/>"
    children_html = "".join(_render_node(child) for child in node.children)
    return f"<{node.tag}{attrs_str}>{children_html}</{node.tag}>"

def _escape_html(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def parse_html(html: str) -> HtmlNode:
    parser = SimpleHtmlParser()
    parser.feed(html)
    return parser.root

def extract_notice_items_from_node(node: HtmlNode, page_url: str, category: str) -> list[dict]:
    items: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for link in iter_nodes(node):
        if link.tag != "a" or not is_notice_link(link):
            continue
        attr_title = clean_text(link.attrs.get("title") or "")
        text_title = clean_text(strip_notice_prefixes(text_content(link) or ""))
        title = attr_title or text_title
        if not is_notice_title(title):
            continue
        href = link.attrs.get("href", "")
        normalized_href = href.strip().lower()
        if (
            not normalized_href
            or normalized_href == "#"
            or normalized_href.startswith("javascript:")
        ):
            continue
        absolute_url = urljoin(page_url, href)
        row_text = clean_text(text_content(record_container(link)) or title)
        date = extract_date(row_text)
        key = (title, absolute_url or "")
        if key in seen:
            continue
        seen.add(key)
        items.append(
            {
                "category": category,
                "title": title,
                "date": date,
                "url": absolute_url,
                "summary": notice_summary(row_text, title, date),
                "source": "jwxt",
            }
        )
    return items


def is_notice_link(link: HtmlNode) -> bool:
    """排除栏目标题、表头和导航链接，只保留通知记录中的链接。"""
    if any(ancestor.tag in {"h1", "h2", "h3", "h4", "h5", "h6", "th", "nav"} for ancestor in ancestors(link)):
        return False
    title = clean_text(strip_notice_prefixes(text_content(link) or ""))
    return title not in _NON_NOTICE_TITLES

def is_notice_section(node: HtmlNode) -> bool:
    marker = " ".join(
        [
            node.attrs.get("id", ""),
            node.attrs.get("class", ""),
            node.attrs.get("name", ""),
            node.attrs.get("data-type", ""),
        ]
    ).lower()
    if any(token in marker for token in ("newsnotice", "notice", "message", "news", "tzgg", "xwgg", "gggl")):
        return True
    title = section_title(node)
    return bool(title and any(word in title for word in ("通知", "公告", "消息", "新闻")))

def section_title(node: HtmlNode) -> str | None:
    for child in node.children:
        if isinstance(child, HtmlNode) and child.tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            title = clean_text(text_content(child).replace("更多", ""))
            if title:
                return title
    for child in iter_nodes(node):
        class_name = child.attrs.get("class", "")
        if child.tag in {"h1", "h2", "h3", "h4", "h5", "h6"} or "index_title" in class_name or "panel-title" in class_name or "widget-title" in class_name or (child.tag == "span" and "title" in class_name):
            title = clean_text(text_content(child).replace("更多", ""))
            if title:
                return title
    return None

def extract_more_url(node: HtmlNode) -> str | None:
    for item in iter_nodes(node):
        marker = " ".join([item.attrs.get("class", ""), item.attrs.get("id", "")]).lower()
        text = clean_text(text_content(item))
        if "title-more" not in marker and text != "更多":
            continue
        url = url_from_attrs(item.attrs)
        if url:
            return url
        for child in iter_nodes(item):
            url = url_from_attrs(child.attrs)
            if url:
                return url
    return None

def url_from_attrs(attrs: dict[str, str]) -> str | None:
    for key in ("href", "data-url", "url"):
        value = attrs.get(key, "").strip()
        if value and not value.lower().startswith("javascript:void"):
            return value
    joined = " ".join(attrs.values())
    match = HTML_URL_PATTERN.search(joined)
    return match.group(1) if match else None

def record_container(node: HtmlNode) -> HtmlNode:
    current = node
    while current.parent is not None:
        if current.parent.tag in {"li", "tr", "dd", "p"}:
            return current.parent
        current = current.parent
    return node

def iter_nodes(node: HtmlNode):
    yield node
    for child in node.children:
        if isinstance(child, HtmlNode):
            yield from iter_nodes(child)

def ancestors(node: HtmlNode):
    current = node.parent
    while current is not None:
        yield current
        current = current.parent

def text_content(node: HtmlNode) -> str:
    parts: list[str] = []
    for child in node.children:
        if isinstance(child, str):
            parts.append(child)
        elif isinstance(child, HtmlNode):
            parts.append(text_content(child))
    return "".join(parts)

def clean_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()

def strip_notice_prefixes(value: str) -> str:
    for pattern in NOTICE_PREFIX_PATTERNS:
        value = pattern.sub("", value)
    return value.strip()

def is_notice_title(title: str) -> bool:
    if not title or title in _NON_NOTICE_TITLES or title.lower() == "more":
        return False
    return len(title) >= 2

def extract_date(value: str) -> str | None:
    match = DATE_PATTERN.search(value)
    return match.group(0) if match else None

def notice_summary(row_text: str, title: str, date: str | None) -> str | None:
    summary = row_text.replace(title, "", 1)
    if date:
        summary = summary.replace(date, "", 1)
    summary = clean_text(summary)
    return summary or None
