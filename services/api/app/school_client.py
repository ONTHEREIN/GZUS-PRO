from __future__ import annotations

import base64
import importlib
import re
import time
from json import JSONDecodeError
from dataclasses import dataclass, field
from datetime import datetime
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin, urlparse

from app.school_sdk_patches import apply_school_sdk_import_patches, apply_school_sdk_patches

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
        info["photoDataUrl"] = self.get_student_photo()
        return info

    def get_student_photo(self) -> str | None:
        student_id = self._account
        if not student_id:
            return None
        try:
            response = self._proxy_response(
                "GET",
                PHOTO_URL,
                params={"xh_id": student_id, "zplx": "rxhzp"},
            )
        except Exception:  # noqa: BLE001 - photo is optional.
            return None
        content = getattr(response, "content", b"") or b""
        if not content:
            return None
        content_type = getattr(response, "headers", {}).get("content-type", "image/jpeg")
        if "html" in content_type.lower():
            return None
        encoded = base64.b64encode(content).decode("ascii")
        return f"data:{content_type.split(';', 1)[0]};base64,{encoded}"

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
        index_page_url = urljoin(f"{self.base_url}/", "xtgl/index_initMenu.html")
        response = self._proxy_response(
            "GET",
            INDEX_URL,
            params={"echarts": "1", "_t": str(int(time.time() * 1000))},
        )
        html = self._response_text(response)
        sections = extract_notice_sections(html, index_page_url)
        all_items: list[dict] = []
        seen: set[tuple[str, str, str]] = set()
        for section in sections:
            items = section["items"]
            more_url = section.get("moreUrl")
            if more_url:
                try:
                    full_url = urljoin(index_page_url, more_url)
                    page_response = self._proxy_response("GET", self._endpoint_from_url(full_url))
                    page_items = extract_notice_items(
                        self._response_text(page_response),
                        full_url,
                        section.get("category") or "",
                    )
                    if page_items:
                        items = page_items
                except Exception:  # noqa: BLE001 - fallback to homepage section items.
                    pass
            for item in items:
                key = (item.get("category") or "", item.get("title") or "", item.get("url") or "")
                if item.get("title") and key not in seen:
                    seen.add(key)
                    all_items.append(item)
        return all_items

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
            return text
        content = getattr(response, "content", None)
        if isinstance(content, bytes):
            for encoding in ("utf-8", "gbk", "gb18030"):
                try:
                    return content.decode(encoding)
                except UnicodeDecodeError:
                    continue
            return content.decode("utf-8", errors="ignore")
        return str(content or "")

    def _proxy_json(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        response = self._proxy_response(method, url_or_endpoint, **kwargs)
        try:
            return response.json()
        except JSONDecodeError as exc:
            raise AuthenticationError("教务系统会话已失效，请重新登录") from exc

    def _proxy_response(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        if self._client is None or not hasattr(self._client, "proxy_request"):
            raise MissingProxySlotError("当前 school-sdk user client 不支持 proxy_request")
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
    }


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
        if not is_notice_section(node):
            continue
        if any(
            ancestor.tag in {"div", "section", "article", "ul"} and is_notice_section(ancestor)
            for ancestor in ancestors(node)
        ):
            continue
        category = section_title(node) or "通知"
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
        title = clean_text(text_content(link) or link.attrs.get("title") or "")
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
    if any(token in marker for token in ("newsnotice", "notice", "message", "news", "tzgg")):
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
        if child.tag in {"h1", "h2", "h3", "h4", "h5", "h6"} or "index_title" in class_name:
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
    match = re.search(r"['\"]([^'\"]+\.html(?:\?[^'\"]*)?)['\"]", joined)
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


def is_notice_title(title: str) -> bool:
    if not title or title in {"更多", "more", "MORE"}:
        return False
    return len(title) >= 2


def extract_date(value: str) -> str | None:
    match = re.search(r"\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?", value)
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
