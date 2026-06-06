from __future__ import annotations

import base64
import importlib
import logging
import re
import time
from functools import lru_cache
from json import JSONDecodeError
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin, urlparse

from app.school_sdk_patches import apply_school_sdk_import_patches, apply_school_sdk_patches

logger = logging.getLogger(__name__)

TERM_TO_XQM = {1: "3", 2: "12", 3: "16"}

EXAM_URL = "/jwglxt/kwgl/kscx_cxXsksxxIndex.html"
EXAM_GNMKDM = "N358105"

SCHEDULE_URL = "/jwglxt/kbcx/xskbcx_cxXsKb.html"
SCHEDULE_GNMKDM = "N2151"

ATTENDANCE_URL = "/jwglxt/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html"
ATTENDANCE_GNMKDM = "N254315"
ATTENDANCE_PAGE_SIZE = 50

CREDIT_URL = "/jwglxt/design/funcData_cxFuncDataList.html"
CREDIT_FUNC_WIDGET_GUID = "37234863CD24BB76E063860810AC3761"
CREDIT_GNMKDM = "N255022"

PHOTO_URL = "/jwglxt/xtgl/photo_cxXszp4.html"
INDEX_URL = "/jwglxt/xtgl/index_initMenu.html"
NEWS_URL = "/jwglxt/xtgl/index_cxNews.html"
NOTICE_MORE_URL = "/jwglxt/xtgl/xwck_cxMoreXwList.html"
DBSY_URL = "/jwglxt/xtgl/index_cxDbsy.html"

DATE_PATTERN = re.compile(r'\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?')
RANGE_PATTERN = re.compile(r'(\d+)\s*-\s*(\d+)')
NUMBER_PATTERN = re.compile(r'\d+')
NOTICE_PREFIX_PATTERNS = [re.compile(p) for p in [r'【[^】]*】', r'\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?']]
HTML_URL_PATTERN = re.compile(r"['\"]([^'\"]+\.html(?:\?[^'\"]*)?)['\"]")

CACHE_TTL = timedelta(minutes=10)


def simple_cache(ttl: timedelta):
    def decorator(func):
        cache = {}
        
        def wrapper(*args, **kwargs):
            key = (args, frozenset(kwargs.items()))
            now = datetime.now()
            if key in cache:
                cached_value, expiry = cache[key]
                if now < expiry:
                    return cached_value
            result = func(*args, **kwargs)
            cache[key] = (result, now + ttl)
            return result
        return wrapper
    return decorator


class AuthenticationError(RuntimeError):
    pass


class MissingProxySlotError(NotImplementedError):
    pass


@dataclass
class CaptchaChallenge:
    token: str
    image: str
    client: "SchoolSdkClient"


class CaptchaRequired(RuntimeError):
    def __init__(self, challenge: CaptchaChallenge) -> None:
        super().__init__("captcha required")
        self.challenge = challenge


class SchoolSdkClient:
    """Thin adapter over FarmerChillax/new-school-sdk with normalized output."""

    def __init__(self, base_url: str, timeout_seconds: int = 15) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self._client: Any | None = None
        self._account: str | None = None

    def login(self, account: str, password: str) -> str | None:
        client_cls = self._load_school_client()
        self._client = self._build_client(client_cls)
        self._account = account
        try:
            result = self._call_login(self._client, account, password)
            if self._has_academic_methods(result):
                self._client = result
        except Exception as exc:  # noqa: BLE001 - third-party SDK exceptions are not stable.
            if self._looks_like_captcha(exc):
                raise CaptchaRequired(CaptchaChallenge(token="", image="", client=self)) from exc
            raise AuthenticationError("教务系统登录失败") from exc
        return self._extract_student_name(result)

    def login_with_cookies(self, cookies: Any, account: str) -> str | None:
        cookie = self._select_sdk_cookie(cookies)
        if not cookie:
            raise AuthenticationError("未获取到教务系统 cookie")
        cookie_pairs = self._cookie_pairs(cookies)
        client_cls = self._load_school_client()
        school_client = self._build_client(client_cls)
        method = getattr(school_client, "user_login_with_cookies", None)
        if method is None:
            raise AuthenticationError("当前 SDK 未提供 cookie 登录方法")
        self._account = account
        try:
            result = method(cookie, account=account)
            if self._has_academic_methods(result):
                self._client = result
            else:
                self._client = school_client
            self._apply_cookie_pairs(cookie_pairs)
        except Exception as exc:  # noqa: BLE001 - third-party SDK exceptions are not stable.
            self._client = None
            raise AuthenticationError("教务系统 cookie 登录验证失败") from exc
        return self._student_name_from_logged_in_client(result)

    def submit_captcha(self, code: str) -> str | None:
        if self._client is None:
            raise AuthenticationError("验证码会话已失效")
        if not hasattr(self._client, "user_login_captcha"):
            raise AuthenticationError("当前 SDK 未暴露验证码提交接口")
        try:
            result = self._client.user_login_captcha(code)
        except Exception as exc:  # noqa: BLE001
            raise AuthenticationError("验证码提交失败") from exc
        return self._extract_student_name(result)

    def get_info(self) -> dict:
        result = self._call_first(["get_info", "get_student_info", "info"])
        info = normalize_student_info(result)
        if not info.get("major"):
            try:
                credits = self.get_credits()
            except Exception:  # noqa: BLE001 - optional enrichment only.
                credits = []
            if credits:
                info["major"] = credits[0].get("major") or info.get("major")
                info["college"] = credits[0].get("college") or info.get("college")
                info["grade"] = credits[0].get("grade") or info.get("grade")
        student_id = info.get("studentId") or None
        if student_id:
            self._account = student_id
        try:
            info["photoDataUrl"] = self.get_student_photo(student_id)
        except Exception as exc:  # noqa: BLE001 - photo is optional enrichment, log and continue.
            logger.warning("get_info: get_student_photo failed for student_id=%s: %s", student_id, exc)
            info["photoDataUrl"] = None
        return info

    def get_student_photo(self, student_id: str | None = None) -> str | None:
        student_id = (student_id or self._account or "").strip()
        if not student_id:
            logger.warning("get_student_photo: no student_id")
            return None
        response = self._fetch_photo_response(student_id)
        if response is None:
            logger.warning("get_student_photo: all fallbacks returned None for student_id=%s", student_id)
            return None
        content = getattr(response, "content", b"") or b""
        if not content:
            logger.warning("get_student_photo: empty content for student_id=%s", student_id)
            return None
        content_type = getattr(response, "headers", {}).get("content-type", "image/jpeg")
        if "html" in content_type.lower():
            logger.warning("get_student_photo: got HTML instead of image for student_id=%s", student_id)
            return None
        detected_type = _detect_image_mime(content)
        if detected_type:
            content_type = detected_type
        converted, final_type = _normalize_image_to_png(content, content_type)
        if converted is not None:
            content = converted
            content_type = final_type
        encoded = base64.b64encode(content).decode("ascii")
        logger.info("get_student_photo: success, size=%d bytes, type=%s", len(content), content_type)
        return f"data:{content_type.split(';', 1)[0]};base64,{encoded}"

    def _fetch_photo_response(self, student_id: str) -> Any:
        try:
            result = self._proxy_response(
                "GET",
                PHOTO_URL,
                params={"xh_id": student_id, "zplx": "rxhzp"},
            )
            logger.debug("_fetch_photo_response: proxy_request succeeded")
            return result
        except MissingProxySlotError:
            logger.info("_fetch_photo_response: proxy_request not available, falling back to _http")
        except Exception as exc:  # noqa: BLE001
            logger.warning("_fetch_photo_response: proxy_request failed: %s", exc)
        return self._fetch_photo_via_http(student_id)

    def _fetch_photo_via_http(self, student_id: str) -> Any:
        http = getattr(self._client, "_http", None) if self._client else None
        if http is not None:
            try:
                photo_url = urljoin(f"{self.base_url}/", PHOTO_URL.lstrip("/"))
                logger.debug("_fetch_photo_via_http: requesting %s", photo_url)
                return http.get(photo_url, params={"xh_id": student_id, "zplx": "rxhzp"})
            except Exception as exc:  # noqa: BLE001
                logger.warning("_fetch_photo_via_http: failed: %s", exc)
        else:
            logger.info("_fetch_photo_via_http: _http not available on client")
        return self._fetch_photo_via_httpx(student_id)

    def _fetch_photo_via_httpx(self, student_id: str) -> Any:
        cookie_jar = getattr(getattr(self._client, "_http", None), "cookies", None) if self._client else None
        if cookie_jar is None:
            logger.info("_fetch_photo_via_httpx: no cookie jar available")
            return None
        try:
            import httpx as _httpx
            cookies = {name: value for name, value in cookie_jar.items()}
            photo_url = urljoin(f"{self.base_url}/", PHOTO_URL.lstrip("/"))
            with _httpx.Client(timeout=self.timeout_seconds, follow_redirects=True, cookies=cookies) as client:
                return client.get(photo_url, params={"xh_id": student_id, "zplx": "rxhzp"})
        except Exception:  # noqa: BLE001
            return None

    def get_schedule(self, year: str | None, term: str | None) -> list[dict]:
        year, term = default_academic_period(year, term)
        apply_school_sdk_patches()
        result = self._query_schedule_via_proxy(year, term)
        return [normalize_schedule_course(item) for item in ensure_list(result)]

    def get_exams(self, year: str | None, term: str | None) -> list[dict]:
        year, term = default_academic_period(year, term)
        try:
            result = self._call_first(["get_exam_schedule", "get_exams", "get_exam"], year, term)
        except NotImplementedError:
            result = self._query_exams_via_proxy(year, term)
        return [normalize_exam_item(item) for item in ensure_list(result)]

    def get_grades(self, year: str | None, term: str | None) -> list[dict]:
        year, term = default_academic_period(year, term)
        result = self._call_first(["get_score", "get_scores", "get_grades"], year, term)
        return [normalize_grade_item(item) for item in ensure_grade_list(result)]

    def get_attendance(self, year: str | None, term: str | None) -> list[dict]:
        year, term = default_academic_period(year, term)
        result = self._query_attendance(year, term)
        return [normalize_attendance_item(item) for item in ensure_list(result)]

    def get_credits(self) -> list[dict]:
        result = self._query_credits()
        return [normalize_credit_item(item) for item in ensure_list(result)]

    def get_notices(self) -> list[dict]:
        return self._query_notices()

    def get_notice_detail(self, url: str) -> dict:
        return self._query_notice_detail(url)

    def logout(self) -> None:
        if self._client is not None and hasattr(self._client, "logout"):
            self._client.logout()

    def _load_school_client(self) -> Any:
        apply_school_sdk_import_patches()
        apply_school_sdk_patches()
        candidates = [
            ("school_sdk", "SchoolClient"),
            ("school_sdk.client", "SchoolClient"),
            ("new_school_sdk", "SchoolClient"),
        ]
        for module_name, class_name in candidates:
            try:
                module = importlib.import_module(module_name)
            except ModuleNotFoundError:
                continue
            client_cls = getattr(module, class_name, None)
            if client_cls is not None:
                return client_cls
        raise AuthenticationError("未安装 school-sdk，请运行 pip install -e '.[school]'")

    def _build_client(self, client_cls: Any) -> Any:
        parsed = urlparse(self.base_url)
        if parsed.scheme and parsed.netloc:
            host = parsed.hostname or parsed.netloc
            ssl = parsed.scheme == "https"
            port = parsed.port or (443 if ssl else 80)
            prefix = parsed.path.rstrip("/")
            endpoints = prefixed_url_endpoints(prefix) if prefix else None
            return client_cls(
                host=host,
                port=port,
                ssl=ssl,
                timeout=self.timeout_seconds,
                login_url_path=f"{prefix}/xtgl/login_slogin.html" if prefix else None,
                url_endpoints=endpoints,
            )
        attempts = [
            {"base_url": self.base_url, "timeout": self.timeout_seconds},
            {"host": self.base_url, "timeout": self.timeout_seconds},
            {"url": self.base_url},
            self.base_url,
        ]
        last_error: Exception | None = None
        for args in attempts:
            try:
                return client_cls(**args) if isinstance(args, dict) else client_cls(args)
            except TypeError as exc:
                last_error = exc
        if last_error is not None:
            raise last_error
        return client_cls()

    def _call_login(self, client: Any, account: str, password: str) -> Any:
        for name in ("user_login", "login"):
            method = getattr(client, name, None)
            if method is None:
                continue
            try:
                return method(account, password)
            except TypeError:
                return method(username=account, password=password)
        raise AuthenticationError("SDK 未提供登录方法")

    def _call_first(self, names: list[str], *args: str | int | dict | None) -> Any:
        if self._client is None:
            raise AuthenticationError("尚未登录")
        clean_args = [arg for arg in args if arg not in (None, "")]
        last_error: Exception | None = None
        for name in names:
            method = getattr(self._client, name, None)
            if method is None:
                continue
            for call_args in (clean_args, []):
                try:
                    return method(*call_args)
                except TypeError as exc:
                    last_error = exc
        if last_error is not None:
            raise last_error
        raise NotImplementedError(f"SDK 未提供 {', '.join(names)}")

    def _query_schedule_via_proxy(self, year: int, term: int) -> list[dict]:
        data = self._proxy_json(
            "POST",
            SCHEDULE_URL,
            data={
                "xnm": str(year),
                "xqm": TERM_TO_XQM.get(term, ""),
                "kzlx": "ck",
                "_search": "false",
                "nd": str(int(time.time() * 1000)),
                "queryModel.showCount": "100",
                "queryModel.currentPage": "1",
                "queryModel.sortName": "",
                "queryModel.sortOrder": "asc",
                "time": "1",
            },
        )
        return data.get("kbList", []) if isinstance(data, dict) else []

    def _query_exams_via_proxy(self, year: int, term: int) -> dict:
        return self._proxy_json(
            "POST",
            EXAM_URL,
            params={"doType": "query", "gnmkdm": EXAM_GNMKDM},
            data={
                "xnm": str(year),
                "xqm": TERM_TO_XQM.get(term, ""),
                "ksmcdmb_id": "",
                "kch": "",
                "kc": "",
                "ksrq": "",
                "_search": "false",
                "nd": str(int(time.time() * 1000)),
                "queryModel.showCount": "50",
                "queryModel.currentPage": "1",
                "queryModel.sortName": "",
                "queryModel.sortOrder": "asc",
                "time": "1",
            },
        )

    def _query_attendance(self, year: int, term: int) -> list[dict]:
        all_items: list[dict] = []
        current_page = 1
        total_pages = 1
        while current_page <= total_pages:
            data = self._proxy_json(
                "POST",
                ATTENDANCE_URL,
                params={"doType": "query", "gnmkdm": ATTENDANCE_GNMKDM},
                data={
                    "xh": self._account or "",
                    "xm": "",
                    "xh_id": "",
                    "xnm": str(year),
                    "xqm": TERM_TO_XQM.get(term, ""),
                    "kch": "",
                    "kch_id": "",
                    "gnmkdm": ATTENDANCE_GNMKDM,
                    "queryModel.showCount": str(ATTENDANCE_PAGE_SIZE),
                    "queryModel.currentPage": str(current_page),
                    "queryModel.sortName": "",
                    "queryModel.sortOrder": "asc",
                },
            )
            if current_page == 1:
                total_pages = int(
                    data.get("totalPage") or data.get("totalPages") or data.get("pageCount") or 1
                )
            page_items = data.get("items", [])
            if not page_items:
                break
            all_items.extend(page_items)
            if len(page_items) < ATTENDANCE_PAGE_SIZE:
                break
            current_page += 1
        return all_items

    def _query_credits(self) -> list[dict]:
        data = self._proxy_json(
            "POST",
            CREDIT_URL,
            params={"func_widget_guid": CREDIT_FUNC_WIDGET_GUID, "gnmkdm": CREDIT_GNMKDM},
            data={
                "gnmkdm": CREDIT_GNMKDM,
                "xh": self._account or "",
                "queryModel.showCount": "15",
                "queryModel.currentPage": "1",
                "queryModel.sortName": " ",
                "queryModel.sortOrder": "asc",
            },
        )
        return data.get("items", []) if isinstance(data, dict) else []

    def _query_notices(self) -> list[dict]:
        news_page_url = urljoin(f"{self.base_url}/", "xtgl/index_cxNews.html")
        logger.info("Fetching notices from news page: %s", NEWS_URL)
        try:
            response = self._proxy_response(
                "GET",
                NEWS_URL,
                params={"localeKey": "zh_CN", "_t": str(int(time.time() * 1000))},
            )
        except MissingProxySlotError:
            raise
        except Exception as exc:
            logger.error("Failed to fetch notices news page: %s", exc)
            raise
        html = self._response_text(response)
        html_lower = html.lower()
        has_login_page_marker = "login_slogin" in html
        if not has_login_page_marker:
            has_login_page_marker = bool(re.search(r'<input[^>]*type\s*=\s*["\']password["\']', html_lower))
        if has_login_page_marker:
            logger.warning("Notices news page appears to be a login page, session may be expired")
            raise AuthenticationError("教务系统会话已失效，请重新登录")
        sections = extract_notice_sections(html, news_page_url)
        logger.info("Parsed %d notice sections from news page", len(sections))
        all_items: list[dict] = []
        seen: set[tuple[str, str, str]] = set()
        for section in sections:
            items = section["items"]
            more_url = section.get("moreUrl") or NOTICE_MORE_URL
            section["moreUrl"] = more_url
            if more_url and len(items) < 3:
                try:
                    full_url = urljoin(news_page_url, more_url)
                    endpoint = self._endpoint_from_url(full_url)
                    logger.debug("Following 'more' link: %s", endpoint)
                    page_response = self._proxy_response("GET", endpoint)
                    page_items = extract_notice_items(
                        self._response_text(page_response),
                        full_url,
                        section.get("category") or "",
                    )
                    if page_items:
                        items = page_items
                        logger.debug("Got %d items from 'more' page", len(page_items))
                except Exception:  # noqa: BLE001 - fallback to news page items.
                    logger.warning("Failed to follow 'more' link %s, using news page items", more_url, exc_info=True)
                    pass
            for item in items:
                key = (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                if item.get("title") and key not in seen:
                    seen.add(key)
                    all_items.append(item)
        # Also fetch notices from DBSY_URL (待办事宜)
        try:
            dbsy_response = self._proxy_response(
                "GET",
                DBSY_URL,
                params={"localeKey": "zh_CN", "_t": str(int(time.time() * 1000))},
            )
            dbsy_html = self._response_text(dbsy_response)
            dbsy_page_url = urljoin(f"{self.base_url}/", DBSY_URL.lstrip("/"))
            dbsy_sections = extract_notice_sections(dbsy_html, dbsy_page_url)
            for section in dbsy_sections:
                for item in section["items"]:
                    key = (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                    if item.get("title") and key not in seen:
                        seen.add(key)
                        all_items.append(item)
            logger.info("Added %d items from DBSY page", len(dbsy_sections))
        except Exception as exc:  # noqa: BLE001 - DBSY is optional
            logger.warning("Failed to fetch DBSY notices: %s", exc)
        logger.info("Returning %d notice items total", len(all_items))
        self._fetch_content_summaries_sync(all_items)
        return all_items

    def _fetch_content_summary(self, url: str) -> str | None:
        try:
            endpoint = self._endpoint_from_url(url)
            response = self._proxy_response("GET", endpoint)
            html = self._response_text(response)
            detail = extract_notice_detail(html, url)
            content = detail.get("contentHtml", "")
            clean = re.sub(r"<[^>]+>", "", content).strip()
            clean = re.sub(r"\s+", " ", clean)
            return clean[:120] if clean else None
        except Exception:
            return None

    def _fetch_content_summaries_sync(self, items: list[dict]) -> None:
        items_with_url = [(i, item) for i, item in enumerate(items) if item.get("url")]
        if not items_with_url:
            return

        from concurrent.futures import ThreadPoolExecutor, as_completed

        def fetch_one(idx: int, url: str) -> tuple[int, str | None]:
            return idx, self._fetch_content_summary(url)

        try:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = {
                    executor.submit(fetch_one, idx, item["url"]): idx
                    for idx, item in items_with_url
                }
                for future in as_completed(futures, timeout=10.0):
                    try:
                        idx, summary = future.result(timeout=5.0)
                        if summary is not None:
                            items[idx]["content_summary"] = summary
                    except Exception:
                        pass
        except Exception:
            pass

    def _query_notice_detail(self, url: str) -> dict:
        endpoint = self._endpoint_from_url(url)
        logger.info("Fetching notice detail: %s", endpoint)
        try:
            response = self._proxy_response("GET", endpoint)
        except MissingProxySlotError:
            raise
        except Exception as exc:
            logger.error("Failed to fetch notice detail: %s", exc)
            raise
        html = self._response_text(response)
        html_lower = html.lower()
        has_login_page_marker = "login_slogin" in html
        if not has_login_page_marker:
            has_login_page_marker = bool(re.search(r'<input[^>]*type\s*=\s*["\']password["\']', html_lower))
        if has_login_page_marker:
            raise AuthenticationError("教务系统会话已失效，请重新登录")
        return extract_notice_detail(html, url)

    def _endpoint_from_url(self, url: str) -> str:
        parsed = urlparse(url)
        base = urlparse(self.base_url)
        if parsed.netloc and parsed.netloc != base.netloc:
            return url
        endpoint = parsed.path or "/"
        if parsed.query:
            endpoint = f"{endpoint}?{parsed.query}"
        return endpoint

    @staticmethod
    def _response_text(response: Any) -> str:
        text = getattr(response, "text", None)
        if isinstance(text, str):
            logger.debug("response_text: %d chars from .text", len(text))
            return text
        content = getattr(response, "content", None)
        if isinstance(content, bytes):
            for encoding in ("utf-8", "gbk", "gb18030"):
                try:
                    decoded = content.decode(encoding)
                    logger.debug("response_text: %d chars from .content (%s)", len(decoded), encoding)
                    return decoded
                except UnicodeDecodeError:
                    continue
            result = content.decode("utf-8", errors="ignore")
            logger.debug("response_text: %d chars from .content (fallback utf-8 ignore)", len(result))
            return result
        logger.warning("response_text: no .text or .content on response object")
        return str(content or "")

    def _proxy_json(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        response = self._proxy_response(method, url_or_endpoint, **kwargs)
        try:
            return response.json()
        except JSONDecodeError as exc:
            raise AuthenticationError("教务系统会话已失效，请重新登录") from exc

    def _proxy_response(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        if self._client is None or not hasattr(self._client, "proxy_request"):
            raise MissingProxySlotError("当前登录方式不支持获取通知，请尝试重新登录")
        logger.debug("proxy_request %s %s", method, url_or_endpoint)
        return self._client.proxy_request(method, url_or_endpoint, **kwargs)

    @staticmethod
    def _looks_like_captcha(exc: Exception) -> bool:
        message = str(exc).lower()
        return "captcha" in message or "验证码" in message or "滑块" in message

    @staticmethod
    def _has_academic_methods(value: Any) -> bool:
        return any(hasattr(value, name) for name in ("get_info", "get_schedule", "get_score"))

    @staticmethod
    def _extract_student_name(result: Any) -> str | None:
        if isinstance(result, dict):
            return result.get("name") or result.get("xm") or result.get("studentName")
        return getattr(result, "name", None) or getattr(result, "xm", None)

    def _student_name_from_logged_in_client(self, result: Any) -> str | None:
        name = self._extract_student_name(result)
        if name:
            return name
        try:
            info = normalize_student_info(
                self._call_first(["get_info", "get_student_info", "info"])
            )
            student_id = info.get("studentId")
            if student_id:
                self._account = student_id
            return info.get("name")
        except Exception:  # noqa: BLE001 - cookie login can still be valid without a readable name.
            return None

    @staticmethod
    def _select_sdk_cookie(cookies: Any) -> str:
        pairs = SchoolSdkClient._cookie_pairs(cookies)
        for key, value in pairs:
            if key.upper() == "JSESSIONID":
                return f"{key}={value}"
        if pairs:
            key, value = pairs[0]
            return f"{key}={value}"
        return ""

    @staticmethod
    def _cookie_pairs(cookies: Any) -> list[tuple[str, str]]:
        if isinstance(cookies, str):
            pairs = []
            for part in cookies.split(";"):
                text = part.strip()
                if not text or "=" not in text:
                    continue
                key, value = text.split("=", 1)
                key = key.strip()
                if key:
                    pairs.append((key, value.strip()))
            return pairs
        pairs: list[tuple[str, str]] = []
        if hasattr(cookies, "items"):
            pairs = [(str(key), str(value)) for key, value in cookies.items()]
        else:
            try:
                pairs = [(str(cookie.name), str(cookie.value)) for cookie in cookies]
            except TypeError:
                pairs = []
        return [(key, value) for key, value in pairs if key]

    def _apply_cookie_pairs(self, pairs: list[tuple[str, str]]) -> None:
        if self._client is None or not hasattr(self._client, "_http"):
            return
        cookie_jar = getattr(self._client._http, "cookies", None)
        if cookie_jar is None:
            return
        for key, value in pairs:
            cookie_jar.set(key, value, domain="jwxt.seig.edu.cn", path="/")
            cookie_jar.set(key, value, domain="jwxt.seig.edu.cn", path="/jwglxt")


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


def ensure_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("items", "data", "rows", "courses", "scores", "exams"):
            nested = value.get(key)
            if isinstance(nested, list):
                return nested
        return [value]
    return list(value) if isinstance(value, tuple) else [value]


def ensure_grade_list(value: Any) -> list[Any]:
    if isinstance(value, dict):
        if not value:
            return []
        if any(isinstance(item, dict) for item in value.values()):
            return list(value.values())
    return ensure_list(value)


def as_dict(value: Any) -> dict:
    if isinstance(value, dict):
        return value
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if hasattr(value, "dict"):
        return value.dict()
    return vars(value)


def pick(data: dict, *keys: str) -> Any:
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return None


def normalize_student_info(value: Any) -> dict:
    data = as_dict(value)
    return {
        "studentId": str(
            pick(data, "studentId", "student_id", "student_number", "xh", "account", "id") or ""
        ),
        "name": str(pick(data, "name", "xm", "studentName") or ""),
        "college": pick(data, "college", "xy", "department", "department_name"),
        "major": pick(data, "major", "zy", "zymc", "majorName", "professionName"),
        "className": pick(data, "className", "class_name", "bj", "class", "bjmc"),
        "grade": pick(data, "grade", "nj"),
    }


def normalize_schedule_course(value: Any) -> dict:
    data = as_dict(value)
    start_section, end_section = parse_section_range(
        pick(data, "startSection", "start_section", "jc_start", "ksjc", "jcs", "jc")
    )
    return {
        "name": str(pick(data, "name", "courseName", "kcmc") or ""),
        "teacher": pick(data, "teacher", "jsxm", "teacherName", "xm"),
        "classroom": pick(data, "classroom", "location", "cdmc"),
        "weekday": pick(data, "weekday", "weekDay", "xqj"),
        "startSection": start_section,
        "endSection": end_section,
        "weeks": pick(data, "weeks", "zcd", "week"),
        "raw": data,
    }


def normalize_exam_item(value: Any) -> dict:
    data = as_dict(value)
    return {
        "courseName": str(pick(data, "courseName", "name", "kcmc") or ""),
        "time": pick(data, "time", "kssj", "examTime"),
        "location": pick(data, "location", "cdmc", "examPlace"),
        "seat": pick(data, "seat", "zwh", "seatNo"),
        "type": pick(data, "type", "kslx", "ksfs", "ksmc"),
        "credit": str(pick(data, "credit", "xf") or ""),
        "campus": pick(data, "campus", "cdxqmc"),
        "remark": pick(data, "remark", "ksbz"),
    }


def normalize_grade_item(value: Any) -> dict:
    data = as_dict(value)
    return {
        "courseName": str(pick(data, "courseName", "course_name", "name", "kcmc") or ""),
        "score": str(pick(data, "score", "exam_score", "exam_result", "cj") or ""),
        "credit": str(pick(data, "credit", "xf") or ""),
        "gradePoint": str(pick(data, "gradePoint", "jd", "gpa", "grade_point") or ""),
        "term": pick(data, "term", "xq", "semester"),
    }


def normalize_attendance_item(value: Any) -> dict:
    data = as_dict(value)
    return {
        "courseName": str(pick(data, "courseName", "kcmc", "name") or ""),
        "courseCode": pick(data, "courseCode", "kch"),
        "academicYear": pick(data, "academicYear", "xnmc", "xn"),
        "term": str(pick(data, "term", "xqmc", "xq") or ""),
        "normal": int(pick(data, "normal", "cs_01") or 0),
        "late": int(pick(data, "late", "cs_02") or 0),
        "leaveEarly": int(pick(data, "leaveEarly", "cs_03") or 0),
        "absent": int(pick(data, "absent", "cs_04") or 0),
        "leave": int(pick(data, "leave", "cs_05") or 0),
        "total": int(pick(data, "total", "totalresult") or 0),
        "records": normalize_attendance_records(data),
    }


def normalize_attendance_records(data: dict) -> list[dict]:
    raw_records = pick(
        data,
        "records",
        "recordList",
        "details",
        "detailList",
        "history",
        "items",
        "mx",
        "list",
    )
    if raw_records is None:
        return []
    records = []
    for item in ensure_list(raw_records):
        record = as_dict(item)
        date = pick(record, "date", "attendanceDate", "kqrq", "rq", "day", "time", "createdAt")
        status = attendance_status_code(pick(record, "status", "type", "zt", "statusCode", "kqzt"))
        count = int(pick(record, "count", "times", "num") or 1)
        records.append(
            {
                "date": str(date or ""),
                "status": status,
                "statusLabel": attendance_status_label(status),
                "count": max(1, count),
                "time": str(pick(record, "time", "section", "jc", "classTime") or ""),
                "remark": str(pick(record, "remark", "bz", "reason") or ""),
            }
        )
    return records


def attendance_status_code(value: Any) -> str:
    text = str(value or "").strip()
    if text in {"late", "迟到", "cs_02", "2"}:
        return "late"
    if text in {"leaveEarly", "早退", "cs_03", "3"}:
        return "leaveEarly"
    if text in {"absent", "旷课", "缺勤", "cs_04", "4"}:
        return "absent"
    if text in {"leave", "请假", "cs_05", "5"}:
        return "leave"
    return "normal"


def attendance_status_label(status: str) -> str:
    return {
        "late": "迟到",
        "leaveEarly": "早退",
        "absent": "旷课",
        "leave": "请假",
    }.get(status, "正常")


def normalize_credit_item(value: Any) -> dict:
    data = as_dict(value)
    required_expected = float(pick(data, "requiredExpected", "yqxf_01") or 0)
    elective_expected = float(pick(data, "electiveExpected", "yqxf_02") or 0)
    other_expected = float(pick(data, "otherExpected", "yqxf_03") or 0)
    required_earned = float(pick(data, "requiredEarned", "sxxf_01") or 0)
    elective_earned = float(pick(data, "electiveEarned", "sxxf_02") or 0)
    other_earned = float(pick(data, "otherEarned", "sxxf_03") or 0)
    return {
        "studentId": pick(data, "studentId", "xh"),
        "name": pick(data, "name", "xm"),
        "college": pick(data, "college", "jgmc"),
        "major": pick(data, "major", "zymc"),
        "grade": str(pick(data, "grade", "nj") or ""),
        "totalCredit": str(pick(data, "totalCredit", "zdxf") or ""),
        "requiredCredit": str(pick(data, "requiredCredit", "bxxf") or ""),
        "selectedCredit": str(pick(data, "selectedCredit", "xkxf") or ""),
        "requiredExpected": required_expected,
        "electiveExpected": elective_expected,
        "otherExpected": other_expected,
        "requiredEarned": required_earned,
        "electiveEarned": elective_earned,
        "otherEarned": other_earned,
        "totalExpected": required_expected + elective_expected + other_expected,
        "totalEarned": required_earned + elective_earned + other_earned,
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
    items = []
    seen: set[tuple[str, str]] = set()
    for link in iter_nodes(node):
        if link.tag != "a":
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
            }
        )
    for table in iter_nodes(node):
        if table.tag != "table":
            continue
        for link in iter_nodes(table):
            if link.tag != "a":
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
                }
            )
    return items


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
    if not title or title in {"更多", "more", "MORE"}:
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


def parse_section_range(value: Any) -> tuple[int | None, int | None]:
    if value in (None, ""):
        return None, None
    parts = str(value).replace("，", ",").split("-", 1)
    try:
        start = int(parts[0].strip())
    except ValueError:
        return None, None
    if len(parts) == 1:
        return start, start
    try:
        end = int(parts[1].strip())
    except ValueError:
        end = start
    return start, end


def default_academic_period(year: str | int | None, term: str | int | None) -> tuple[int, int]:
    if year not in (None, "") and term not in (None, ""):
        return int(year), int(term)
    now = datetime.now()
    academic_year = now.year if now.month >= 9 else now.year - 1
    academic_term = 1 if now.month >= 9 or now.month <= 1 else 2
    return int(year or academic_year), int(term or academic_term)


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
