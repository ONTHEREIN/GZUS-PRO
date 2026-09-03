from __future__ import annotations

import base64
import logging
import re
import time
from json import JSONDecodeError
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin, urlparse

# 学年/学期判定已抽到 academic_period.py（上海时区），此处保留 re-export 兼容旧调用。
from app.academic_period import default_academic_period  # noqa: F401
from app.jwxt.normalizers import (
    ensure_grade_list,  # noqa: F401
    ensure_list,
    extract_credit_items,
    normalize_attendance_detail,
    normalize_attendance_item,
    normalize_credit_item,
    normalize_exam_item,
    normalize_grade_item,
    normalize_schedule_course,
    normalize_student_info,
)
from app.jwxt.notice_parser import (
    extract_notice_detail,
    extract_notice_items,
    extract_notice_sections,
)
# 向后兼容 re-export：拆分前这些符号定义在 school_client.py，tests 仍按原名导入
from app.jwxt.normalizers import (  # noqa: F401
    as_dict,
    attendance_status_code,
    attendance_status_label,
    credit_total_count,
    normalize_attendance_records,
    parse_section_range,
    pick,
)
from app.jwxt.notice_parser import (  # noqa: F401
    HtmlNode,
    SimpleHtmlParser,
    parse_html,
)
from app.school_sdk_patches import apply_school_sdk_import_patches, apply_school_sdk_patches, apply_school_sdk_info_patch
from app.jwxt.photo_utils import (
    _detect_image_mime,
    _extract_encoded_photo_url,
    _normalize_image_to_png,
    prefixed_url_endpoints,
)

logger = logging.getLogger(__name__)

# Retry configuration for upstream JWXT requests
_MAX_RETRIES = 2
_RETRY_BACKOFF_BASE = 0.5  # seconds

TERM_TO_XQM = {1: "3", 2: "12", 3: "16"}

EXAM_URL = "/jwglxt/kwgl/kscx_cxXsksxxIndex.html"
EXAM_GNMKDM = "N358105"

SCHEDULE_URL = "/jwglxt/kbcx/xskbcx_cxXsKb.html"

GRADE_URL = "/jwglxt/cjcx/cjcx_cxDgXscj.html"
GRADE_GNMKDM = "N305005"

ATTENDANCE_URL = "/jwglxt/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html"
ATTENDANCE_GNMKDM = "N254315"
ATTENDANCE_PAGE_SIZE = 50
ATTENDANCE_DETAIL_URL = "/jwglxt/jxdmgl/jxdmqk_cxXsmd.html"

CREDIT_URL = "/jwglxt/design/funcData_cxFuncDataList.html"
CREDIT_FUNC_WIDGET_GUID = "555A63AA3F6BB8E4E065CAE6002842BA"
CREDIT_GNMKDM = "N255022"

PHOTO_URL = "/jwglxt/xtgl/photo_cxXszp4.html"
INFO_URL = "/jwglxt/xsxxxggl/xsgrxxwh_cxXsgrxx.html"
INFO_GNMKDM = "N100801"
NEWS_URL = "/jwglxt/xtgl/index_cxNews.html"
NOTICE_MORE_URL = "/jwglxt/xtgl/xwck_cxMoreXwList.html"
DBSY_URL = "/jwglxt/xtgl/index_cxDbsy.html"


class AuthenticationError(RuntimeError):
    pass


class MissingProxySlotError(NotImplementedError):
    pass


class AttendanceCourseNotFoundError(LookupError):
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

    def __init__(
        self,
        base_url: str,
        timeout_seconds: int = 15,
        httpx_client: Any | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self._client: Any | None = None
        self._account: str | None = None
        self._student_name: str | None = None
        self._httpx_client: Any | None = httpx_client

    def _jwxt_origin(self) -> str:
        """Return the origin used for JWXT requests.

        请求始终直接发送至学校教务系统。
        """
        parsed = urlparse(self.base_url)
        return f"{parsed.scheme}://{parsed.netloc}"

    def _jwxt_headers(self, extra: dict | None = None) -> dict:
        """返回附加到学校请求的 headers。"""
        return dict(extra or {})

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
            raise AuthenticationError("统一认证登录失败") from exc
        name = self._extract_student_name(result)
        if name:
            self._student_name = name
        return name

    def login_with_cookies(self, cookies: Any, account: str, validate: bool = True) -> str | None:
        cookie = self._select_sdk_cookie(cookies)
        if not cookie:
            raise AuthenticationError("未获取到教务系统 cookie")
        cookie_pairs = self._cookie_pairs(cookies)
        client_cls = self._load_school_client()
        school_client = self._build_client(client_cls)
        self._account = account

        if not validate:
            # 不验证 cookie 即恢复 SDK 客户端；首次业务请求会完成真实校验。
            method = getattr(school_client, "user_login_with_cookies", None)
            if method is None:
                raise AuthenticationError("当前 SDK 未提供 cookie 登录方法")
            try:
                self._client = method(cookie, account=account)
            except Exception as exc:  # noqa: BLE001 - third-party SDK exceptions are not stable.
                raise AuthenticationError("教务系统 cookie 初始化失败") from exc
            self._apply_cookie_pairs(cookie_pairs)
            return None

        method = getattr(school_client, "user_login_with_cookies", None)
        if method is None:
            raise AuthenticationError("当前 SDK 未提供 cookie 登录方法")
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
        name = self._student_name_from_logged_in_client(result)
        if name:
            self._student_name = name
        return name

    def submit_captcha(self, code: str) -> str | None:
        if self._client is None:
            raise AuthenticationError("验证码会话已失效")
        if not hasattr(self._client, "user_login_captcha"):
            raise AuthenticationError("当前 SDK 未暴露验证码提交接口")
        try:
            result = self._client.user_login_captcha(code)
        except Exception as exc:  # noqa: BLE001
            raise AuthenticationError("验证码提交失败") from exc
        name = self._extract_student_name(result)
        if name:
            self._student_name = name
        return name

    def get_info(self) -> dict:
        # Try SDK first
        info: dict = {}
        photo_url_from_html: str | None = None
        try:
            result = self._call_first(["get_info", "get_student_info", "info"])
            # Check if SDK's raw HTML is actually a login page (session expired)
            sdk_html_is_login = False
            if self._client is not None:
                info_obj = getattr(self._client, "info", None)
                if info_obj is not None:
                    raw_html = getattr(info_obj, "raw_info", None)
                    if raw_html is not None:
                        html_text = raw_html if isinstance(raw_html, str) else raw_html.decode("utf-8", errors="replace") if isinstance(raw_html, bytes) else str(raw_html)
                        if "col_xh" in html_text:
                            # Valid info page – extract photo URL
                            photo_url_from_html = _extract_encoded_photo_url(html_text)
                        elif "login_slogin" in html_text:
                            logger.warning("get_info: SDK fetched login page instead of info page, session may be stale")
                            sdk_html_is_login = True
            if not sdk_html_is_login:
                info = normalize_student_info(result)
        except Exception as exc:  # noqa: BLE001
            logger.warning("get_info: SDK get_info failed: %s, trying fallbacks", exc)

        # If SDK returned empty/incomplete data, try fetching info page HTML directly
        _info_keys = (
            "studentId", "name", "college", "major", "className", "grade",
            "gender", "idNumber", "birthDate", "ethnicity", "politicalStatus",
            "enrollDate", "nativePlace", "studentStatus", "educationLevel",
            "phone", "email", "address",
        )
        _has_incomplete = (
            not info.get("name") or not info.get("className") or not info.get("gender")
        )
        # Also trigger fallback when SDK returned garbled data (GBK decoded as UTF-8)
        _looks_garbled_info = (
            info.get("name") and SchoolSdkClient._looks_garbled(str(info["name"]))
        )
        if _has_incomplete or _looks_garbled_info:
            html_info = self._query_info_via_html()
            if html_info:
                for key in _info_keys:
                    if not info.get(key) and html_info.get(key):
                        info[key] = html_info[key]
                if not photo_url_from_html:
                    photo_url_from_html = html_info.get("_photoUrl")

        # If still empty, try proxy-based JSON query
        if not info.get("name") or not info.get("className"):
            try:
                proxy_info = self._query_info_via_proxy()
                if proxy_info:
                    for key in _info_keys:
                        if not info.get(key) and proxy_info.get(key):
                            info[key] = proxy_info[key]
            except Exception as exc:  # noqa: BLE001
                logger.warning("get_info: proxy info fallback failed: %s", exc)

        # Enrich from credits if major/college/grade still missing
        if not info.get("major"):
            try:
                credits = self.get_credits()
            except Exception:  # noqa: BLE001 - optional enrichment only.
                credits = []
            if credits:
                info["major"] = credits[0].get("major") or info.get("major")
                info["college"] = credits[0].get("college") or info.get("college")
                info["grade"] = credits[0].get("grade") or info.get("grade")

        # Backfill studentId from account if still missing
        if not info.get("studentId") and self._account:
            info["studentId"] = self._account

        # Backfill name from login if still missing
        if not info.get("name") and self._student_name:
            info["name"] = self._student_name

        student_id = info.get("studentId") or None
        if student_id:
            self._account = student_id
        try:
            info["photoDataUrl"] = self.get_student_photo(
                student_id, encoded_photo_url=photo_url_from_html,
            )
        except Exception as exc:  # noqa: BLE001 - photo is optional enrichment, log and continue.
            logger.warning("get_info: get_student_photo failed for student_id=%s: %s", student_id, exc)
            info["photoDataUrl"] = None
        return info

    def _query_info_via_html(self) -> dict | None:
        """Fetch the student info page HTML directly and parse it with the patched _parse."""
        html = self._fetch_info_page_html()
        if not html or "col_xh" not in html:
            return None
        # Parse HTML directly with pyquery instead of relying on SDK's _parse patch
        try:
            from pyquery import PyQuery as pq

            doc = pq(html)
            parsed = {
                "student_number": doc("#col_xh > p").text(),
                "name": doc("#col_xm > p").text(),
                "department_name": doc("#col_jg_id > p").text() or doc("#col_jg > p").text(),
                "class_name": doc("#col_bh_id > p").text() or doc("#col_bh > p").text(),
                "grade": doc("#col_njdm_id > p").text() or doc("#col_nj > p").text(),
                "major": doc("#col_zyh_id > p").text() or doc("#col_zyfx_id > p").text() or doc("#col_zy > p").text(),
                "gender": doc("#col_xbm > p").text(),
                "zjhm": doc("#col_zjhm > p").text(),
                "csrq": doc("#col_csrq > p").text(),
                "mzm": doc("#col_mzm > p").text(),
                "zzmmm": doc("#col_zzmmm > p").text(),
                "rxrq": doc("#col_rxrq > p").text(),
                "jg": doc("#col_jg > p").text(),
                "xjztdm": doc("#col_xjztdm > p").text(),
                "pyccdm": doc("#col_pyccdm > p").text(),
                "sjhm": doc("#col_sjhm > p").text(),
                "dzyx": doc("#col_dzyx > p").text(),
                "jtdz": doc("#col_jtdz > p").text(),
            }
            result = normalize_student_info(parsed)
            # Also extract photo URL
            photo_url = _extract_encoded_photo_url(html)
            if photo_url:
                result["_photoUrl"] = photo_url
            return result
        except Exception as exc:  # noqa: BLE001
            logger.warning("_query_info_via_html: parse failed: %s", exc)
            return None

    def _fetch_info_page_html(self) -> str | None:
        """GET the student info page HTML via httpx_client or proxy."""
        params = {
            "gnmkdm": INFO_GNMKDM,
            "layout": "default",
            "su": self._account or "",
        }
        # Try httpx_client first
        if self._httpx_client is not None:
            origin = self._jwxt_origin()
            full_url = origin + INFO_URL
            try:
                response = self._httpx_client.get(full_url, params=params, timeout=self.timeout_seconds)
                response.raise_for_status()
                html = self._response_text(response)
                if "col_xh" in html:
                    return html
                logger.debug("_fetch_info_page_html: httpx_client returned page without col_xh")
            except Exception as exc:
                logger.debug("_fetch_info_page_html: httpx_client failed: %s", exc)

        # Try proxy
        try:
            response = self._proxy_response("GET", INFO_URL, params=params)
            html = self._response_text(response)
            if html and "col_xh" in html:
                return html
            logger.debug("_fetch_info_page_html: proxy returned page without col_xh")
        except (AuthenticationError, MissingProxySlotError):
            pass
        except Exception as exc:
            logger.debug("_fetch_info_page_html: proxy failed: %s", exc)

        return None

    def _query_info_via_proxy(self) -> dict | None:
        """Fetch student info via proxy POST to the JWXT info API endpoint."""
        try:
            data = self._proxy_json(
                "POST",
                INFO_URL,
                params={"gnmkdm": INFO_GNMKDM},
                data={
                    "xh_id": self._account or "",
                    "xh": self._account or "",
                    "_search": "false",
                    "nd": str(int(time.time() * 1000)),
                    "queryModel.showCount": "1",
                    "queryModel.currentPage": "1",
                    "queryModel.sortName": "",
                    "queryModel.sortOrder": "asc",
                    "time": "1",
                },
            )
        except (AuthenticationError, MissingProxySlotError):
            return None
        except Exception as exc:  # noqa: BLE001
            logger.warning("_query_info_via_proxy: request failed: %s", exc)
            return None

        if not isinstance(data, dict):
            return None

        # The API may return data in different structures
        items = data.get("items") or data.get("data") or []
        if isinstance(items, list) and items:
            raw = items[0] if isinstance(items[0], dict) else {}
        elif isinstance(items, dict):
            raw = items
        else:
            # Some endpoints return the student info directly at top level
            raw = data

        return normalize_student_info(raw)

    def get_student_photo(self, student_id: str | None = None, *, encoded_photo_url: str | None = None) -> str | None:
        # Try encoded photo URL first (new JWXT format with encrypted student ID)
        if encoded_photo_url:
            try:
                response = self._fetch_encoded_photo_response(encoded_photo_url)
                result = self._process_photo_response(response, "encoded_url")
                if result is not None:
                    return result
            except Exception as exc:  # noqa: BLE001
                logger.warning("get_student_photo: encoded URL failed: %s, falling back", exc)

        student_id = (student_id or self._account or "").strip()
        if not student_id:
            logger.warning("get_student_photo: no student_id")
            return None
        response = self._fetch_photo_response(student_id)
        if response is None:
            logger.warning("get_student_photo: all fallbacks returned None for student_id=%s", student_id)
            return None
        return self._process_photo_response(response, student_id)

    def _process_photo_response(self, response: Any, label: str) -> str | None:
        """Convert an HTTP response containing a student photo to a data URL."""
        content = getattr(response, "content", b"") or b""
        if not content:
            logger.warning("get_student_photo: empty content for %s", label)
            return None
        content_type = getattr(response, "headers", {}).get("content-type", "image/jpeg")
        if "html" in content_type.lower():
            logger.warning("get_student_photo: got HTML instead of image for %s", label)
            return None
        detected_type = _detect_image_mime(content)
        if detected_type:
            content_type = detected_type
        converted, final_type = _normalize_image_to_png(content, content_type)
        if converted is not None:
            content = converted
            content_type = final_type
        encoded = base64.b64encode(content).decode("ascii")
        logger.info("get_student_photo: success for %s, size=%d bytes, type=%s", label, len(content), content_type)
        return f"data:{content_type.split(';', 1)[0]};base64,{encoded}"

    def _fetch_encoded_photo_response(self, encoded_url: str) -> Any:
        """Fetch photo using the new encoded URL format (photo_cxEncodedXszp.html)."""
        # encoded_url is a relative path like /jwglxt/photo/photo_cxEncodedXszp.html?...
        if self._httpx_client is not None:
            origin = self._jwxt_origin()
            full_url = origin + encoded_url
            try:
                response = self._httpx_client.get(full_url, timeout=self.timeout_seconds)
                response.raise_for_status()
                ct = response.headers.get("content-type", "")
                if "html" not in ct.lower() and len(response.content or b"") > 0:
                    return response
            except Exception as exc:
                logger.debug("_fetch_encoded_photo_response: httpx failed: %s", exc)

        try:
            return self._proxy_response("GET", encoded_url)
        except (AuthenticationError, MissingProxySlotError):
            return None
        except Exception as exc:
            logger.debug("_fetch_encoded_photo_response: proxy failed: %s", exc)
            return None

    def _fetch_photo_response(self, student_id: str) -> Any:
        if self._httpx_client is not None:
            result = self._fetch_photo_via_httpx_client(student_id)
            if result is not None:
                return result
            logger.debug("_fetch_photo_response: direct httpx_client failed, trying proxy chain")
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

    def _fetch_photo_via_httpx_client(self, student_id: str) -> Any:
        origin = self._jwxt_origin()
        full_url = origin + PHOTO_URL
        headers = {
            "Referer": f"{origin}/jwglxt/xtgl/index_initMenu.html",
        }
        try:
            response = self._httpx_client.get(
                full_url,
                params={"xh_id": student_id, "zplx": "rxhzp"},
                timeout=self.timeout_seconds,
                headers=headers,
            )
            response.raise_for_status()
            content_type = response.headers.get("content-type", "")
            if "html" in content_type.lower():
                logger.debug("_fetch_photo_via_httpx_client: got HTML, session may be stale")
                return None
            if len(response.content or b"") > 0:
                logger.debug("_fetch_photo_via_httpx_client: got %d bytes", len(response.content))
                return response
            return None
        except Exception as exc:
            logger.debug("_fetch_photo_via_httpx_client: failed: %s", exc)
            return None

    def _fetch_photo_via_http(self, student_id: str) -> Any:
        http = getattr(self._client, "_http", None) if self._client else None
        if http is not None:
            try:
                origin = self._jwxt_origin()
                photo_url = origin + PHOTO_URL
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
            origin = self._jwxt_origin()
            photo_url = origin + PHOTO_URL
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
        result = self._query_grades_via_proxy(year, term)
        return [normalize_grade_item(item) for item in ensure_list(result.get("items", []))]

    def get_attendance(self, year: str | None, term: str | None) -> list[dict]:
        year, term = default_academic_period(year, term)
        result = self._query_attendance(year, term)
        return [normalize_attendance_item(item) for item in ensure_list(result)]

    def get_attendance_details(
        self, year: str | None, term: str | None, course_id: str
    ) -> list[dict]:
        year, term = default_academic_period(year, term)
        course = next(
            (
                item
                for item in self._query_attendance(year, term)
                if str(pick(item, "courseId", "kch_id") or "") == course_id
            ),
            None,
        )
        if course is None:
            raise AttendanceCourseNotFoundError("当前学期未找到该考勤课程")

        student_id = str(pick(course, "xh_id") or "")
        if not student_id:
            raise ValueError("教务系统未返回考勤明细所需的学生标识")

        details: list[dict] = []
        for category_code in ("01", "02", "03", "04", "05"):
            if int(pick(course, f"cs_{category_code}") or 0) <= 0:
                continue
            details.extend(
                self._query_attendance_details(
                    year,
                    term,
                    course_id,
                    student_id,
                    category_code,
                    str(pick(course, "kssj") or ""),
                    str(pick(course, "jssj") or ""),
                )
            )
        normalized = [normalize_attendance_detail(item) for item in details]
        return sorted(
            normalized,
            key=lambda item: (
                item["classDate"],
                item["classTime"],
                item["rollCallTime"],
            ),
            reverse=True,
        )

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

    def get_jwxt_cookies_string(self) -> str:
        """Extract JWXT session cookies as a cookie header string.

        Used to persist cookies for session reconstruction after serverless cold start.
        Returns cookies from _httpx_client (preferred, richer) or _client._http fallback.
        """
        seen: set[str] = set()
        parts: list[str] = []

        # Prefer httpx_client cookies (full jar with domain/path metadata)
        if self._httpx_client is not None:
            try:
                for cookie in self._httpx_client.cookies.jar:
                    name = cookie.name
                    if name and name not in seen:
                        seen.add(name)
                        parts.append(f"{name}={cookie.value}")
            except Exception:
                pass

        # Fallback to school_client._http cookies
        if not parts and self._client is not None:
            try:
                cookie_jar = getattr(getattr(self._client, "_http", None), "cookies", None)
                if cookie_jar is not None:
                    for cookie in cookie_jar:
                        name = cookie.name
                        value = cookie.value
                        if name not in seen:
                            seen.add(name)
                            parts.append(f"{name}={value}")
            except Exception:
                pass

        return "; ".join(parts)

    def _load_school_client(self) -> Any:
        apply_school_sdk_import_patches()
        apply_school_sdk_patches()
        apply_school_sdk_info_patch()
        try:
            from app.vendor.school_sdk.client import SchoolClient as Sc
            return Sc
        except ModuleNotFoundError:
            raise AuthenticationError(
                "未安装 school-sdk，请检查 app/vendor/school_sdk/ 目录是否存在"
            )

    def _build_client(self, client_cls: Any) -> Any:
        parsed = urlparse(self.base_url)
        if parsed.scheme and parsed.netloc:
            host = parsed.hostname or parsed.netloc
            ssl = parsed.scheme == "https"
            port = parsed.port or (443 if ssl else 80)
            prefix = parsed.path.rstrip("/")
            endpoints = prefixed_url_endpoints(prefix) if prefix else None
        else:
            host = None
        if host:
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

    def _query_grades_via_proxy(self, year: int, term: int) -> dict:
        return self._proxy_json(
            "POST",
            GRADE_URL,
            params={"doType": "query", "gnmkdm": GRADE_GNMKDM, "su": self._account or ""},
            data={
                "xnm": str(year),
                "xqm": TERM_TO_XQM.get(term, ""),
                "_search": "false",
                "nd": str(int(time.time() * 1000)),
                "queryModel.showCount": "500",
                "queryModel.currentPage": "1",
                "queryModel.sortName": "",
                "queryModel.sortOrder": "asc",
                "time": "4",
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

    def _query_attendance_details(
        self,
        year: int,
        term: int,
        course_id: str,
        student_id: str,
        category_code: str,
        start_time: str,
        end_time: str,
    ) -> list[dict]:
        all_items: list[dict] = []
        current_page = 1
        total_pages = 1
        while current_page <= total_pages:
            data = self._proxy_json(
                "POST",
                ATTENDANCE_DETAIL_URL,
                params={"doType": "query", "gnmkdm": ATTENDANCE_GNMKDM},
                data={
                    "xnm": str(year),
                    "xqm": TERM_TO_XQM.get(term, ""),
                    "xh_id": student_id,
                    "kch_id": course_id,
                    "kssj": start_time,
                    "jssj": end_time,
                    "dmlbm": category_code,
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
        return extract_credit_items(data)

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
            raise AuthenticationError("登录状态已失效，请重新登录")
        sections = extract_notice_sections(html, news_page_url)
        logger.info("Parsed %d notice sections from news page", len(sections))
        all_items: list[dict] = []
        seen: set[tuple[str, str, str]] = set()
        for section in sections:
            items = section["items"]
            more_url = section.get("moreUrl")
            if not more_url and any(word in (section.get("category") or "") for word in ("通知", "公告", "新闻")):
                more_url = NOTICE_MORE_URL
            if more_url:
                section["moreUrl"] = more_url
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

        # Limit items to fetch summaries for (avoid fetching too many at once)
        max_items = min(len(items_with_url), 20)
        items_with_url = items_with_url[:max_items]

        def fetch_one(idx: int, url: str) -> tuple[int, str | None]:
            return idx, self._fetch_content_summary(url)

        try:
            with ThreadPoolExecutor(max_workers=3) as executor:
                futures = {
                    executor.submit(fetch_one, idx, item["url"]): idx
                    for idx, item in items_with_url
                }
                for future in as_completed(futures, timeout=8.0):
                    try:
                        idx, summary = future.result(timeout=3.0)
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
            raise AuthenticationError("登录状态已失效，请重新登录")
        return extract_notice_detail(html, url)

    def _endpoint_from_url(self, url: str) -> str:
        """将通知 URL 归一化为教务系统同源端点路径。

        仅放行相对路径或与教务系统同 host 的绝对 URL；跨域绝对 URL 一律
        拒绝，防止恶意 url 参数经 vendor SDK 直发 requests 触发 SSRF
        （vendor 的 _request 对完整 URL 会原样请求）。
        """
        parsed = urlparse(url)
        base = urlparse(self.base_url)
        if parsed.scheme not in ("http", "https", ""):
            raise ValueError(f"不支持的通知链接协议: {parsed.scheme or '(空)'}")
        if parsed.netloc and parsed.netloc != base.netloc:
            raise ValueError(f"跨域通知链接被拒绝: {parsed.netloc}")
        endpoint = self._normalize_jwxt_endpoint(parsed.path or "/")
        if parsed.query:
            endpoint = f"{endpoint}?{parsed.query}"
        return endpoint

    def _normalize_jwxt_endpoint(self, endpoint: str) -> str:
        """规范化同源 JWXT 路径，确保基路径仅出现一次。"""
        path = endpoint if endpoint.startswith("/") else f"/{endpoint}"
        prefix = urlparse(self.base_url).path.rstrip("/")
        if not prefix:
            return path
        duplicate_prefix = f"{prefix}{prefix}/"
        while path.startswith(duplicate_prefix):
            path = f"{prefix}/{path[len(duplicate_prefix):]}"
        if path != prefix and not path.startswith(f"{prefix}/"):
            return f"{prefix}/{path.lstrip('/')}"
        return path

    @staticmethod
    def _response_text(response: Any) -> str:
        """Decode response body, preferring bytes-based decoding to avoid
        httpx auto-decoding GBK content as UTF-8 (which produces mojibake).

        Strategy:
        1. Always try to get raw bytes (.content) first
        2. Decode as UTF-8; if the result looks like mojibake (GBK decoded
           as UTF-8), fall back to GBK/GB18030
        3. Only use .text as last resort (when .content is unavailable)
        """
        content = getattr(response, "content", None)
        if isinstance(content, bytes) and content:
            # Try UTF-8 first (covers JSON APIs and most modern pages)
            try:
                utf8_text = content.decode("utf-8")
                if SchoolSdkClient._looks_garbled(utf8_text):
                    logger.debug("response_text: UTF-8 text looks garbled, trying GBK")
                    raise UnicodeDecodeError("utf-8", content, 0, 1, "mojibake detected")
                logger.debug("response_text: %d chars from .content (utf-8)", len(utf8_text))
                return utf8_text
            except UnicodeDecodeError:
                pass
            # Try GBK encodings
            for encoding in ("gb18030", "gbk"):
                try:
                    decoded = content.decode(encoding)
                    logger.debug("response_text: %d chars from .content (%s)", len(decoded), encoding)
                    return decoded
                except UnicodeDecodeError:
                    continue
            # Last resort: UTF-8 with error replacement
            result = content.decode("utf-8", errors="replace")
            logger.debug("response_text: %d chars from .content (fallback utf-8 replace)", len(result))
            return result

        # Fallback: use httpx's .text if no .content available
        text = getattr(response, "text", None)
        if isinstance(text, str) and text:
            logger.debug("response_text: %d chars from .text (fallback)", len(text))
            return text

        logger.warning("response_text: no .text or .content on response object")
        return str(content or "")

    @staticmethod
    def _looks_garbled(text: str) -> bool:
        """Heuristic: detect GBK content that was incorrectly decoded as UTF-8.

        When GBK bytes are decoded as UTF-8, many byte sequences produce
        characters in the Latin-1 Supplement / C1 range (U+0080–U+00FF).
        Legitimate Chinese UTF-8 text has very few of these.
        """
        if not text:
            return False
        # Quick check: if the text contains common Chinese characters, it's
        # probably fine (UTF-8 multi-byte sequences for CJK don't overlap
        # with GBK mojibake patterns in a reversible way).
        suspicious = 0
        total = min(len(text), 200)  # sample first 200 chars
        for ch in text[:total]:
            cp = ord(ch)
            # U+0080–U+00FF: C1 controls + Latin-1 Supplement
            # These appear frequently when GBK double-byte sequences
            # are misinterpreted as UTF-8.
            if 0x0080 <= cp <= 0x00FF:
                suspicious += 1
        # If >15% of sampled characters are in the suspicious range,
        # it's almost certainly garbled GBK→UTF-8 text.
        ratio = suspicious / max(total, 1)
        if ratio > 0.15:
            logger.debug("_looks_garbled: %.1f%% suspicious chars (threshold 15%%)", ratio * 100)
            return True
        return False

    def _proxy_json(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        response = self._proxy_response(method, url_or_endpoint, **kwargs)
        # --- Pre-check: detect HTML login page before attempting JSON parse ---
        # When the JWXT session expires, proxy_request returns an HTML login page
        # instead of JSON.  Detecting this early avoids a confusing JSONDecodeError
        # and provides a clearer error message.
        text = self._response_text(response)
        if self._looks_like_login_page(text):
            logger.warning(
                "proxy_json: response for %s %s appears to be a login page (session expired)",
                method, url_or_endpoint,
            )
            raise AuthenticationError("登录状态已失效，请重新登录")
        try:
            return response.json()
        except JSONDecodeError as exc:
            raise RuntimeError("教务系统返回了非 JSON 数据，请稍后重试") from exc

    def _proxy_response(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        if self._httpx_client is not None:
            return self._proxy_via_httpx(method, url_or_endpoint, **kwargs)
        if self._client is None or not hasattr(self._client, "proxy_request"):
            raise MissingProxySlotError("当前登录方式不支持获取通知，请尝试重新登录")
        logger.debug("proxy_request %s %s", method, url_or_endpoint)
        try:
            return self._client.proxy_request(method, url_or_endpoint, **kwargs)
        except Exception as exc:
            err_text = str(exc).lower()
            if "login_slogin" in err_text or "登录" in err_text:
                logger.warning(
                    "proxy_response: SDK exception suggests session expired for %s %s: %s",
                    method, url_or_endpoint, exc,
                )
                raise AuthenticationError("登录状态已失效，请重新登录") from exc
            raise

    def _proxy_via_httpx(self, method: str, url_or_endpoint: str, **kwargs: Any) -> Any:
        origin = self._jwxt_origin()
        endpoint = self._normalize_jwxt_endpoint(url_or_endpoint)
        full_url = origin + endpoint
        request_kwargs: dict[str, Any] = {}
        params = kwargs.get("params")
        if params:
            request_kwargs["params"] = params
        data = kwargs.get("data")
        if data:
            request_kwargs["data"] = data
        headers = {
            "Referer": f"{origin}/jwglxt/xtgl/index_initMenu.html",
            "X-Requested-With": "XMLHttpRequest",
        }
        request_kwargs.setdefault("headers", {}).update(headers)
        logger.debug("proxy_via_httpx %s %s", method, full_url)
        import httpx

        for attempt in range(_MAX_RETRIES + 1):
            try:
                response = self._httpx_client.request(
                    method.upper(),
                    full_url,
                    timeout=self.timeout_seconds,
                    **request_kwargs,
                )
                response.raise_for_status()
                return response
            except httpx.TimeoutException as exc:
                if attempt < _MAX_RETRIES:
                    wait = _RETRY_BACKOFF_BASE * (2 ** attempt)
                    logger.warning(
                        "proxy_via_httpx: timeout on attempt %d/%d for %s %s, retrying in %.1fs",
                        attempt + 1, _MAX_RETRIES + 1, method, url_or_endpoint, wait,
                    )
                    import time as _time
                    _time.sleep(wait)
                    continue
                logger.error(
                    "proxy_via_httpx: timeout after %d attempts for %s %s",
                    _MAX_RETRIES + 1, method, url_or_endpoint,
                )
                raise RuntimeError("教务系统请求超时，请稍后重试") from exc
            except httpx.ConnectError as exc:
                if attempt < _MAX_RETRIES:
                    wait = _RETRY_BACKOFF_BASE * (2 ** attempt)
                    logger.warning(
                        "proxy_via_httpx: connection error on attempt %d/%d for %s %s, retrying in %.1fs",
                        attempt + 1, _MAX_RETRIES + 1, method, url_or_endpoint, wait,
                    )
                    import time as _time
                    _time.sleep(wait)
                    continue
                logger.error(
                    "proxy_via_httpx: connection failed after %d attempts for %s %s",
                    _MAX_RETRIES + 1, method, url_or_endpoint,
                )
                raise RuntimeError("无法连接教务系统，请稍后重试") from exc
            except httpx.HTTPStatusError as exc:
                status = exc.response.status_code
                logger.warning(
                    "proxy_via_httpx: HTTP %d for %s %s (url=%s)",
                    status, method, url_or_endpoint, full_url,
                )
                if status == 401:
                    raise AuthenticationError("登录状态已失效，请重新登录") from exc
                if status == 404:
                    raise RuntimeError(
                        f"JWXT 接口返回 404 (url={full_url})，可能接口路径已变更"
                    ) from exc
                # 5xx errors are retryable
                if status >= 500 and attempt < _MAX_RETRIES:
                    wait = _RETRY_BACKOFF_BASE * (2 ** attempt)
                    logger.warning(
                        "proxy_via_httpx: HTTP %d on attempt %d/%d for %s %s, retrying in %.1fs",
                        status, attempt + 1, _MAX_RETRIES + 1, method, url_or_endpoint, wait,
                    )
                    import time as _time
                    _time.sleep(wait)
                    continue
                raise RuntimeError(
                    f"JWXT 接口返回 HTTP {status} (url={full_url})，请稍后重试"
                ) from exc

    @staticmethod
    def _looks_like_captcha(exc: Exception) -> bool:
        message = str(exc).lower()
        return "captcha" in message or "验证码" in message or "滑块" in message

    @staticmethod
    def _looks_like_login_page(text: str) -> bool:
        """Check whether the response text looks like a JWXT login page.

        This is used to detect session expiry: when the JWXT session expires,
        requests are redirected to the login page which returns HTML instead
        of the expected JSON.
        """
        if not text or len(text) < 50:
            return False
        text_lower = text.lower()
        # Primary marker: the JWXT login page path
        if "login_slogin" in text_lower:
            return True
        # Secondary marker: a password input field (unlikely in JSON API responses)
        if '<input' in text_lower and 'type="password"' in text_lower:
            return True
        if "<title>" in text_lower and "登录" in text_lower:
            return True
        return False

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
        get_info = getattr(result, "get_info", None)
        if callable(get_info):
            try:
                name = self._extract_student_name(get_info())
                if name:
                    return name
            except Exception:  # noqa: BLE001 - SDK result types are not stable.
                pass
        # Try fetching the JWXT index page which contains the student name
        # This is much lighter than calling get_info() which downloads photos etc.
        try:
            name = self._fetch_student_name_from_index()
            if name:
                return name
        except Exception:  # noqa: BLE001
            pass
        target = self._client if self._client is not None else result
        try:
            get_info = getattr(target, "get_info", None)
            if callable(get_info):
                return self._extract_student_name(get_info())
        except Exception:  # noqa: BLE001
            pass
        return None

    def _fetch_student_name_from_index(self) -> str | None:
        """Fetch student name from the JWXT info page (lightweight, no photo download)."""
        try:
            if self._httpx_client is not None:
                origin = self._jwxt_origin()
                full_url = origin + INFO_URL
                response = self._httpx_client.get(
                    full_url,
                    params={"gnmkdm": INFO_GNMKDM, "su": self._account or ""},
                    timeout=min(self.timeout_seconds, 8),
                )
                html = self._response_text(response)
            else:
                response = self._proxy_response(
                    "GET", INFO_URL,
                    params={"gnmkdm": INFO_GNMKDM, "su": self._account or ""},
                )
                html = self._response_text(response)
            # Extract name from info page HTML: <p id="col_xm">张三</p>
            import re
            match = re.search(r'id="col_xm"[^>]*>\s*<p[^>]*>\s*([^<]+?)\s*</p>', html)
            if match and match.group(1).strip():
                return match.group(1).strip()
            # Fallback: try col_xm without p tag
            match = re.search(r'id="col_xm"[^>]*>([^<]+)', html)
            if match and match.group(1).strip():
                return match.group(1).strip()
        except Exception:  # noqa: BLE001
            pass
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
            for domain in self._jwxt_cookie_domains():
                cookie_jar.set(key, value, domain=domain, path="/")
                cookie_jar.set(key, value, domain=domain, path="/jwglxt")

    def _jwxt_cookie_domains(self) -> list[str]:
        parsed = urlparse(self.base_url)
        domains = [parsed.hostname or "jwxt.gzus.edu.cn", "jwxt.seig.edu.cn", "jwxt.gzus.edu.cn"]
        return list(dict.fromkeys(domain for domain in domains if domain))
