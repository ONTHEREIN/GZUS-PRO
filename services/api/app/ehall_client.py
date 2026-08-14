from __future__ import annotations

import hashlib
import mimetypes
import re
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError, as_completed
from datetime import date
from html import unescape
from threading import Lock
from typing import Any
from urllib.parse import quote

import httpx


class EhallAuthenticationError(RuntimeError):
    pass


TASK_ENDPOINTS: dict[str, str] = {
    "待办": "api/bpm/processes/tasks/pending",
    "申请": "api/bpm/processes/tasks/apply",
    "已办": "api/bpm/processes/tasks/done",
    "关注": "api/bpm/processes/tasks/follow",
    "待阅": "api/bpm/processes/tasks/unread",
    "已阅": "api/bpm/processes/tasks/read",
    "草稿": "api/bpm/processes/tasks/draft",
}
TASK_CATEGORIES = tuple(TASK_ENDPOINTS.keys())

AFFAIRS_ENDPOINT = "api/affair/uis/affairs"
LEAVE_WORKFLOW_NUMBER = "R_S003_B036"
LEAVE_WORKFLOW_PROCESS_ID = "c6a5de7f061020438c0a03707374e7b85d85"
ATTACHMENT_WORKFLOW_NUMBER = "R_S004_B002"

# Retry configuration for ehall upstream requests
_EHALL_MAX_RETRIES = 2
_EHALL_RETRY_BACKOFF_BASE = 0.5  # seconds


class EhallClient:
    def __init__(
        self,
        base_url: str,
        cookies: str | dict[str, str] = "",
        *,
        auth_token: str | None = None,
        timeout_seconds: int = 15,
    ) -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self.timeout_seconds = timeout_seconds
        self._cookies = _cookie_dict(cookies)
        self._auth_token = auth_token
        self._http_client: httpx.Client | None = None

    def _get_http_client(self) -> httpx.Client:
        if self._http_client is None or getattr(self._http_client, "is_closed", True):
            self._http_client = httpx.Client(
                base_url=self.base_url,
                cookies=self._cookies,
                timeout=httpx.Timeout(self.timeout_seconds, connect=5.0),
                follow_redirects=True,
                headers=self._auth_headers(),
                limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
            )
        return self._http_client

    def close(self) -> None:
        if self._http_client is not None and not self._http_client.is_closed:
            self._http_client.close()
            self._http_client = None

    @property
    def cookie_header(self) -> str:
        return "; ".join(f"{key}={value}" for key, value in self._cookies.items())

    def _auth_headers(self) -> dict[str, str]:
        if self._auth_token:
            return {"Authorization": self._auth_token}
        return {}

    def get_notice_items(self, page_size: int = 50, max_pages: int = 10) -> list[dict]:
        items: list[dict] = []
        seen: set[tuple[str, str, str]] = set()
        seen_lock = Lock()
        request_timeout = min(self.timeout_seconds, 5)
        overall_timeout = request_timeout * 2

        def fetch_category(args: tuple[str, str]) -> list[dict]:
            category, endpoint = args
            result = []
            for page_num in range(1, max_pages + 1):
                try:
                    payload = self._get_json(
                        endpoint,
                        {"pageNum": page_num, "pageSize": page_size},
                        timeout_seconds=request_timeout,
                        max_retries=0,
                    )
                except EhallAuthenticationError:
                    raise
                except Exception:
                    break
                records = extract_records(payload)
                if not records:
                    break
                for record in records:
                    item = normalize_task_record(record, category, self.base_url)
                    if item is None:
                        continue
                    key = (item["category"], item["title"], item.get("url") or "")
                    with seen_lock:
                        if key in seen:
                            continue
                        seen.add(key)
                    result.append(item)
                total = extract_total(payload)
                if len(records) < page_size or (total is not None and page_num * page_size >= total):
                    break
            return result

        executor = ThreadPoolExecutor(max_workers=min(len(TASK_ENDPOINTS), 4))
        try:
            futures = {
                executor.submit(fetch_category, (cat, ep)): cat
                for cat, ep in TASK_ENDPOINTS.items()
            }
            try:
                completed = as_completed(futures, timeout=overall_timeout)
                for future in completed:
                    try:
                        result = future.result(timeout=request_timeout)
                        items.extend(result)
                    except EhallAuthenticationError:
                        raise
                    except Exception:
                        continue
            except TimeoutError:
                pass
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
        return items

    def get_progress_overview(self, page_size: int = 30) -> dict:
        items: list[dict] = []
        counts: dict[str, int] = {category: 0 for category in TASK_CATEGORIES}
        seen: set[tuple[str, str, str]] = set()
        seen_lock = Lock()
        request_timeout = min(self.timeout_seconds, 5)
        overall_timeout = request_timeout * 2

        def fetch_category(args: tuple[str, str]) -> tuple[str, list[dict], int]:
            category, endpoint = args
            try:
                payload = self._get_json(
                    endpoint,
                    {"pageNum": 1, "pageSize": page_size},
                    timeout_seconds=request_timeout,
                    max_retries=0,
                )
            except EhallAuthenticationError:
                raise
            except Exception:
                return category, [], 0
            records = extract_records(payload)
            count = extract_total(payload) or len(records)
            result = []
            for record in records:
                item = normalize_progress_record(record, category, self.base_url)
                if item is None:
                    continue
                key = (item["category"], item["title"], item.get("url") or "")
                with seen_lock:
                    if key in seen:
                        continue
                    seen.add(key)
                result.append(item)
            return category, result, count

        executor = ThreadPoolExecutor(max_workers=min(len(TASK_ENDPOINTS), 4))
        try:
            futures = {
                executor.submit(fetch_category, (cat, ep)): cat
                for cat, ep in TASK_ENDPOINTS.items()
            }
            try:
                completed = as_completed(futures, timeout=overall_timeout)
                for future in completed:
                    try:
                        category, result, count = future.result(timeout=request_timeout)
                        counts[category] = count
                        items.extend(result)
                    except EhallAuthenticationError:
                        raise
                    except Exception:
                        continue
            except TimeoutError:
                pass
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
        items.sort(key=lambda item: item.get("date") or "", reverse=True)
        return {
            "categories": [
                {"label": category, "count": counts.get(category, 0)}
                for category in TASK_CATEGORIES
            ],
            "items": items,
        }

    def get_affairs(
        self,
        page_size: int = 200,
        max_pages: int = 10,
        request_timeout_seconds: int | None = None,
        max_retries: int | None = None,
    ) -> list[dict]:
        items: list[dict] = []
        seen: set[str] = set()
        for page_num in range(1, max_pages + 1):
            payload = self._get_json(
                AFFAIRS_ENDPOINT,
                {
                    "pageNum": page_num,
                    "pageSize": page_size,
                },
                timeout_seconds=request_timeout_seconds,
                max_retries=max_retries,
            )
            records = extract_records(payload)
            if not records:
                break
            for record in records:
                item = normalize_affair_record(record, self.base_url)
                if item is None:
                    continue
                key = item.get("id") or item["title"]
                if key in seen:
                    continue
                seen.add(key)
                items.append(item)
            total = extract_total(payload)
            if len(records) < page_size or (total is not None and len(items) >= total):
                break
        return items

    def get_applications(
        self,
        page_size: int = 80,
        max_pages: int = 1,
        request_timeout_seconds: int = 5,
    ) -> list[dict]:
        items = self._get_application_page_set(
            page_size=page_size,
            max_pages=max_pages,
            extra_params={"isCustom": 0, "terminal": 1, "appStatus": 1},
            request_timeout_seconds=request_timeout_seconds,
        )
        if items:
            return items
        return self._get_application_page_set(
            page_size=page_size,
            max_pages=max_pages,
            extra_params={"isCustom": 0, "terminal": 1},
            request_timeout_seconds=request_timeout_seconds,
        )

    def _get_application_page_set(
        self,
        *,
        page_size: int,
        max_pages: int,
        extra_params: dict[str, Any],
        request_timeout_seconds: int | None = None,
    ) -> list[dict]:
        items: list[dict] = []
        seen: set[str] = set()
        for page_num in range(1, max_pages + 1):
            payload = self._get_json(
                AFFAIRS_ENDPOINT,
                {
                    "pageNum": page_num,
                    "pageSize": page_size,
                    **extra_params,
                },
                timeout_seconds=request_timeout_seconds,
                max_retries=0,
            )
            records = extract_records(payload)
            if not records:
                break
            for record in records:
                item = normalize_application_record(record, self.base_url)
                if item is None:
                    continue
                key = item.get("id") or item["title"]
                if key in seen:
                    continue
                seen.add(key)
                items.append(item)
            total = extract_total(payload)
            if len(records) < page_size or (total is not None and len(items) >= total):
                break
        return items

    def fill_leave_application(
        self,
        *,
        start_date: date,
        end_date: date,
        leave_days: int,
        reason: str,
        courses: list[dict],
        attachment_name: str,
        attachment_content: bytes,
    ) -> dict:
        """Best-effort server-side fill hook for the official Linkey BPM form.

        The real BPM form is JavaScript-heavy, so this method only performs the
        stable session/form discovery here. Test and deployment adapters can
        override this method to drive the official form with a browser runtime.
        """
        form_url = (
            f"{self.base_url.rstrip('/')}/bpm/r"
            f"?wf_num={LEAVE_WORKFLOW_NUMBER}&wf_processid={LEAVE_WORKFLOW_PROCESS_ID}#"
        )
        with httpx.Client(
            base_url=self.base_url,
            cookies=self._cookies,
            timeout=self.timeout_seconds,
            follow_redirects=True,
            headers=self._auth_headers(),
        ) as client:
            response = client.get(
                "bpm/r",
                params={
                    "wf_num": LEAVE_WORKFLOW_NUMBER,
                    "wf_processid": LEAVE_WORKFLOW_PROCESS_ID,
                },
            )
        if _looks_like_login(response):
            raise EhallAuthenticationError("办事大厅会话已失效，请重新登录")
        response.raise_for_status()
        if "学生课程请假申请" not in response.text:
            return {
                "status": "needs_manual",
                "message": "已生成请假数据；请打开请假表单后复制填表脚本执行",
                "formUrl": form_url,
                "unmatchedTeachers": _teacher_names(courses),
            }
        attachment_uploaded = self._upload_leave_attachment_from_form(
            response.text,
            attachment_name=attachment_name,
            attachment_content=attachment_content,
        )
        return {
            "status": "filled" if attachment_uploaded else "needs_manual",
            "message": "已上传附件；请在办事大厅表单页执行填表脚本并检查提交"
            if attachment_uploaded
            else "已生成请假数据；请在办事大厅表单页执行填表脚本，再手动上传附件",
            "formUrl": str(response.url),
            "unmatchedTeachers": _teacher_names(courses),
            "attachmentUploaded": attachment_uploaded,
        }

    def _upload_leave_attachment_from_form(
        self,
        form_html: str,
        *,
        attachment_name: str,
        attachment_content: bytes,
    ) -> bool:
        doc_unid = _input_value(form_html, "WF_DocUnid")
        if not doc_unid or not attachment_content:
            return False
        process_id = _input_value(form_html, "WF_Processid") or LEAVE_WORKFLOW_PROCESS_ID
        node_name = _input_value(form_html, "WF_CurrentNodeName") or "申请人"
        local_store = "1" if _input_value(form_html, "localStore") else "0"
        return self.upload_leave_attachment(
            doc_unid=doc_unid,
            process_id=process_id,
            node_name=node_name,
            local_store=local_store,
            attachment_name=attachment_name,
            attachment_content=attachment_content,
        )

    def upload_leave_attachment(
        self,
        *,
        doc_unid: str,
        process_id: str,
        node_name: str,
        local_store: str = "0",
        attachment_name: str,
        attachment_content: bytes,
    ) -> bool:
        if not doc_unid or not attachment_content:
            return False
        content_type = mimetypes.guess_type(attachment_name)[0] or "application/octet-stream"
        with httpx.Client(
            base_url=self.base_url,
            cookies=self._cookies,
            timeout=max(self.timeout_seconds, 30),
            follow_redirects=True,
            headers=self._auth_headers(),
        ) as client:
            response = client.post(
                "bpm/rule",
                params={"wf_num": ATTACHMENT_WORKFLOW_NUMBER},
                data={
                    "DocUnid": doc_unid,
                    "Processid": process_id,
                    "NodeName": quote(node_name, safe=""),
                    "FdName": "file1",
                    "localStore": local_store,
                    "name": attachment_name,
                },
                files={"file": (attachment_name, attachment_content, content_type)},
            )
        if _looks_like_login(response):
            raise EhallAuthenticationError("办事大厅会话已失效，请重新登录")
        response.raise_for_status()
        return not _looks_like_upload_error(response)

    def _get_json(
        self,
        endpoint: str,
        params: dict[str, Any],
        *,
        timeout_seconds: int | None = None,
        max_retries: int | None = None,
    ) -> Any:
        from app.config import get_settings
        settings = get_settings()
        csrf_key = settings.ehall_csrf_key or "lianyi2019"
        timestamp = str(int(time.time() * 1000))
        query = {
            **params,
            "csrfTimestamp": timestamp,
            "csrfToken": hashlib.md5(
                f"timestamp={timestamp},key={csrf_key}".encode("utf-8")
            ).hexdigest(),
        }
        client = self._get_http_client()
        retry_count = _EHALL_MAX_RETRIES if max_retries is None else max(0, max_retries)
        timeout = timeout_seconds if timeout_seconds is not None else self.timeout_seconds

        def request_get():
            if timeout_seconds is None:
                return client.get(endpoint, params=query)
            try:
                return client.get(endpoint, params=query, timeout=timeout)
            except TypeError as exc:
                if "timeout" not in str(exc):
                    raise
                return client.get(endpoint, params=query)

        for attempt in range(retry_count + 1):
            try:
                response = request_get()
                if _looks_like_login(response):
                    raise EhallAuthenticationError("办事大厅会话已失效，请重新登录")
                response.raise_for_status()
                data = response.json()
                meta = data.get("meta") if isinstance(data, dict) else None
                if isinstance(meta, dict) and meta.get("success") is False:
                    message = str(meta.get("message") or "")
                    if "登录" in message or "会话" in message or "权限" in message:
                        raise EhallAuthenticationError("办事大厅会话已失效，请重新登录")
                return data
            except EhallAuthenticationError:
                raise
            except (httpx.TimeoutException, httpx.ConnectError) as exc:
                if attempt < retry_count:
                    wait = _EHALL_RETRY_BACKOFF_BASE * (2 ** attempt)
                    import time as _time
                    _time.sleep(wait)
                    # Refresh timestamp for retry
                    timestamp = str(int(time.time() * 1000))
                    query = {
                        **params,
                        "csrfTimestamp": timestamp,
                        "csrfToken": hashlib.md5(
                            f"timestamp={timestamp},key={csrf_key}".encode("utf-8")
                        ).hexdigest(),
                    }
                    continue
                raise RuntimeError(f"办事大厅请求失败: {exc}") from exc
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code >= 500 and attempt < retry_count:
                    wait = _EHALL_RETRY_BACKOFF_BASE * (2 ** attempt)
                    import time as _time
                    _time.sleep(wait)
                    continue
                raise


def extract_records(payload: Any) -> list[dict]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("records", "list", "items", "rows"):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    for key in ("data", "result"):
        records = extract_records(payload.get(key))
        if records:
            return records
    return []


def extract_total(payload: Any) -> int | None:
    if not isinstance(payload, dict):
        return None
    for key in ("total", "totalCount", "count"):
        value = payload.get(key)
        if isinstance(value, int):
            return value
        if isinstance(value, str) and value.isdigit():
            return int(value)
    for key in ("data", "result"):
        total = extract_total(payload.get(key))
        if total is not None:
            return total
    return None


def normalize_task_record(record: dict, category: str, base_url: str) -> dict | None:
    title = _first_text(
        record,
        [
            "title",
            "subject",
            "taskName",
            "taskTitle",
            "processName",
            "affairName",
            "name",
            "formName",
        ],
    )
    if not title:
        return None
    date = _date_text(
        _first_text(
            record,
            [
                "createTime",
                "createdAt",
                "applyTime",
                "startTime",
                "updateTime",
                "finishTime",
                "endTime",
            ],
        )
    )
    summary_parts = [
        _first_text(record, ["nodeName", "activityName", "statusName", "stateName"]),
        _first_text(record, ["applicantName", "applyUserName", "creatorName", "transactorName"]),
    ]
    summary = " / ".join(part for part in summary_parts if part)
    return {
        "category": f"办事大厅·{category}",
        "title": title,
        "date": date,
        "url": _record_url(record, base_url),
        "summary": summary or None,
    }


def normalize_progress_record(record: dict, category: str, base_url: str) -> dict | None:
    title = _first_text(
        record,
        [
            "title",
            "subject",
            "taskName",
            "taskTitle",
            "processName",
            "affairName",
            "name",
            "formName",
        ],
    )
    if not title:
        return None
    date = _date_text(
        _first_text(
            record,
            [
                "updateTime",
                "finishTime",
                "endTime",
                "createTime",
                "createdAt",
                "applyTime",
                "startTime",
            ],
        )
    )
    current_node = _first_text(
        record,
        ["nodeName", "activityName", "currentNodeName", "stepName", "statusName", "stateName"],
    )
    handler = _first_text(
        record,
        [
            "handlerName",
            "transactorName",
            "dealUserName",
            "operatorName",
            "applicantName",
            "applyUserName",
            "creatorName",
        ],
    )
    summary_parts = [current_node, handler]
    status_value, status_label, progress = _progress_status(category, current_node)
    return {
        "id": _first_text(record, ["orunid", "id", "taskId", "processInstanceId", "processId", "businessId"]),
        "title": title,
        "category": category,
        "status": status_value,
        "statusLabel": status_label,
        "date": date,
        "summary": " / ".join(part for part in summary_parts if part) or None,
        "currentNode": current_node,
        "handler": handler,
        "progress": progress,
        "url": _record_url(record, base_url),
    }


def _progress_status(category: str, current_node: str | None) -> tuple[str, str, int]:
    node = current_node or ""
    if category in {"已办"} or "结束" in node or "完结" in node or "完成" in node:
        return ("done", "已完结", 100)
    if category in {"已阅"}:
        return ("read", "已阅", 100)
    if category in {"待阅"}:
        return ("unread", "待阅", 35)
    if category in {"草稿"}:
        return ("draft", "草稿", 15)
    if category in {"待办"}:
        return ("pending", "待办", 20)
    if category in {"申请"}:
        return ("processing", "办理中", 60)
    if category in {"关注"}:
        return ("follow", "关注", 50)
    return ("unknown", category, 40)


def normalize_affair_record(record: dict, base_url: str) -> dict | None:
    title = _first_text(
        record,
        [
            "name",
            "affairName",
            "serviceName",
            "taskName",
            "title",
            "processName",
        ],
    )
    if not title:
        return None
    affair_id = _first_text(record, ["id", "affairId", "taskId", "processId", "businessId"])
    tags = _tags(record)
    return {
        "id": affair_id,
        "title": title,
        "department": _first_text(
            record,
            ["departmentName", "deptName", "deptNames", "unitName", "orgName", "ownerDeptName"],
        ),
        "type": _first_text(
            record, ["typeName", "affairTypeName", "categoryName", "businessTypeName"]
        ),
        "tags": tags,
        "summary": _first_text(
            record,
            ["summary", "description", "desc", "remark", "serviceObject", "guide"],
        ),
        "url": _affair_url(record, base_url, affair_id),
    }


def normalize_application_record(record: dict, base_url: str) -> dict | None:
    item = normalize_affair_record(record, base_url)
    if item is None:
        return None
    types = _name_list(record.get("types"))
    tags = _tags(record)
    item.update(
        {
            "department": _first_text(
                record,
                ["departmentName", "department", "deptName", "unitName", "orgName"],
            ),
            "type": ", ".join(types)
            or _first_text(record, ["typeName", "affairTypeName", "categoryName"]),
            "tags": tags,
            "summary": _first_text(record, ["describe", "description", "summary", "remark"]),
            "url": _application_url(record, base_url, item.get("id")),
        }
    )
    return item


def _record_url(record: dict, base_url: str) -> str | None:
    direct = _first_text(record, ["url", "link", "detailUrl", "formUrl"])
    if direct:
        if direct.startswith(("http://", "https://")):
            return direct
        if direct.startswith("#/"):
            return base_url.rstrip("/") + "/" + direct
        if direct.startswith("/"):
            return base_url.rstrip("/") + direct
    orunid = record.get("orunid")
    if orunid and str(orunid).strip():
        app_id = record.get("appId", "")
        if app_id:
            return f"{base_url.rstrip('/')}/bpm/rule?wf_num=R_{app_id}_B036&wf_docunid={orunid}"
        return f"{base_url.rstrip('/')}/#/affairprocess?taskId={orunid}"
    for key in ("id", "taskId", "processInstanceId", "processId", "businessId"):
        value = record.get(key)
        if value is not None and str(value).strip():
            return f"{base_url.rstrip('/')}/#/affairprocess?taskId={value}"
    return None


def _affair_url(record: dict, base_url: str, affair_id: str | None) -> str | None:
    direct = _first_text(record, ["url", "link", "detailUrl", "formUrl", "applyUrl"])
    if direct:
        if direct.startswith(("http://", "https://")):
            return direct
        if direct.startswith("#/"):
            return base_url.rstrip("/") + "/" + direct
        if direct.startswith("/"):
            return base_url.rstrip("/") + direct
    if affair_id:
        return f"{base_url.rstrip('/')}/#/affairs/copyAllAffairs/guide/{affair_id}?id=bsdt"
    return f"{base_url.rstrip('/')}/#/affairs/copyAllAffairs?id=bsdt"


def _application_url(record: dict, base_url: str, affair_id: str | None) -> str | None:
    direct = _first_text(record, ["url", "link", "detailUrl", "formUrl", "applyUrl"])
    if direct and direct != "无":
        if direct.startswith(("http://", "https://")):
            return direct
        if direct.startswith("#/"):
            return base_url.rstrip("/") + "/" + direct
        if direct.startswith("/"):
            return base_url.rstrip("/") + direct
    if affair_id:
        return f"{base_url.rstrip('/')}/#/affairs/copyAllAffairs/guide/{affair_id}?id=yyzx"
    return f"{base_url.rstrip('/')}/#/affairs/copyAllAffairs?id=yyzx"


def _first_text(record: dict, keys: list[str]) -> str | None:
    for key in keys:
        value = record.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return None


def _tags(record: dict) -> list[str]:
    value = None
    for key in ("tags", "tagNames", "labels", "keywords"):
        if key in record:
            value = record[key]
            break
    if value is None:
        return []
    if isinstance(value, str):
        return [part.strip() for part in value.replace("，", ",").split(",") if part.strip()]
    if isinstance(value, list):
        tags = []
        for item in value:
            if isinstance(item, dict):
                text = _first_text(item, ["name", "tagName", "label", "title"])
            else:
                text = str(item).strip()
            if text:
                tags.append(text)
        return tags
    return []


def _name_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    names: list[str] = []
    for item in value:
        if isinstance(item, dict):
            text = _first_text(item, ["name", "typeName", "title"])
        else:
            text = str(item).strip()
        if text:
            names.append(text)
    return names


def _date_text(value: str | None) -> str | None:
    if not value:
        return None
    text = value.strip()
    return text[:19] if len(text) >= 19 else text


def _cookie_dict(cookies: str | dict[str, str]) -> dict[str, str]:
    if isinstance(cookies, dict):
        return {str(key): str(value) for key, value in cookies.items() if key and value}
    pairs: dict[str, str] = {}
    for part in cookies.split(";"):
        text = part.strip()
        if not text or "=" not in text:
            continue
        key, value = text.split("=", 1)
        if key.strip() and value.strip():
            pairs[key.strip()] = value.strip()
    return pairs


def _input_value(html: str, field_id: str) -> str | None:
    pattern = re.compile(r"<input\b(?=[^>]*\bid=['\"]?" + re.escape(field_id) + r"['\"]?)[^>]*>", re.I)
    match = pattern.search(html)
    if match is None:
        pattern = re.compile(
            r"<input\b(?=[^>]*\bname=['\"]?" + re.escape(field_id) + r"['\"]?)[^>]*>",
            re.I,
        )
        match = pattern.search(html)
    if match is None:
        return None
    value_match = re.search(r"\bvalue=(['\"])(.*?)\1", match.group(0), re.I | re.S)
    if value_match is None:
        value_match = re.search(r"\bvalue=([^\s>]+)", match.group(0), re.I)
    if value_match is None:
        return ""
    return unescape(value_match.group(2 if value_match.lastindex == 2 else 1)).strip()


def _looks_like_upload_error(response: httpx.Response) -> bool:
    text = response.text[:2000].lower()
    if not text:
        return False
    markers = ("error", "exception", "失败", "错误", "未上传", "not allowed", "denied")
    return any(marker in text for marker in markers)


def _looks_like_login(response: httpx.Response) -> bool:
    final_url = str(response.url).lower()
    if "/auth" in final_url or "cas" in final_url or "login" in final_url:
        return True
    content_type = response.headers.get("content-type", "").lower()
    if "json" in content_type:
        return False
    text = response.text[:2000].lower()
    return "lyuapserver/login" in text or "caslogin" in text or "password" in text


def _teacher_names(courses: list[dict]) -> list[str]:
    names: list[str] = []
    for course in courses:
        teacher = str(course.get("teacher") or "").strip()
        if teacher and teacher not in names:
            names.append(teacher)
    return names
