from datetime import date

import pytest

from app.ehall_client import (
    EhallClient,
    EhallAuthenticationError,
    extract_records,
    extract_total,
    normalize_affair_record,
    normalize_task_record,
)


def test_extract_records_reads_common_ehall_shapes():
    assert extract_records({"data": {"records": [{"title": "申请一"}]}}) == [{"title": "申请一"}]
    assert extract_records({"data": {"list": [{"title": "申请二"}]}}) == [{"title": "申请二"}]
    assert extract_total({"data": {"total": "12"}}) == 12


def test_search_staff_posts_captured_organization_directory_request(monkeypatch):
    calls = []

    class FakeResponse:
        url = "https://ehall.gzus.edu.cn/bpm/r?wf_num=D_S007_J001"
        headers = {"content-type": "application/json"}
        text = ""

        def raise_for_status(self):
            pass

        def json(self):
            return {
                "total": 1,
                "rows": [
                    {
                        "JobTitle": "教职工",
                        "Userid": "teacher-1",
                        "CnName": "张老师",
                    }
                ],
            }

    class FakeHttpClient:
        def post(self, endpoint, *, params, data, headers):
            calls.append(
                {
                    "endpoint": endpoint,
                    "params": params,
                    "data": data,
                    "headers": headers,
                }
            )
            return FakeResponse()

    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")
    monkeypatch.setattr(client, "_get_http_client", lambda: FakeHttpClient())

    records = client.search_staff("张老师")

    assert records == [
        {"JobTitle": "教职工", "Userid": "teacher-1", "CnName": "张老师"}
    ]
    assert calls == [
        {
            "endpoint": "bpm/r",
            "params": {"wf_num": "D_S007_J001", "wf_gridnum": "V_S007_G001"},
            "data": {
                "searchStr": "张老师",
                "page": "1",
                "rows": "25",
                "sort": "SortNumber",
                "order": "asc",
            },
            "headers": {
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "X-Requested-With": "XMLHttpRequest",
            },
        }
    ]


def test_normalize_task_record_maps_to_notice_item():
    item = normalize_task_record(
        {
            "subject": "学生请假申请",
            "createTime": "2026-06-01 09:10:11",
            "nodeName": "辅导员审批",
            "applicantName": "张三",
            "taskId": "task-1",
        },
        "待办",
        "https://ehall.gzus.edu.cn/",
    )

    assert item == {
        "category": "办事大厅·待办",
        "title": "学生请假申请",
        "date": "2026-06-01 09:10:11",
        "url": "https://ehall.gzus.edu.cn/#/affairprocess?taskId=task-1",
        "summary": "辅导员审批 / 张三",
        "source": "ehall",
    }


def test_normalize_affair_record_maps_to_business_item():
    item = normalize_affair_record(
        {
            "id": "affair-1",
            "name": "学生请假",
            "departmentName": "学生处",
            "typeName": "学生服务",
            "tagNames": "请假,审批",
            "description": "在线提交请假申请",
        },
        "https://ehall.gzus.edu.cn/",
    )

    assert item == {
        "id": "affair-1",
        "title": "学生请假",
        "department": "学生处",
        "type": "学生服务",
        "tags": ["请假", "审批"],
        "summary": "在线提交请假申请",
        "url": "https://ehall.gzus.edu.cn/#/affairs/copyAllAffairs/guide/affair-1?id=bsdt",
    }


def test_ehall_client_adds_csrf_and_normalizes(monkeypatch):
    requests = []

    class FakeResponse:
        url = "https://ehall.gzus.edu.cn/api/bpm/processes/tasks/apply"
        headers = {"content-type": "application/json"}
        text = ""

        def raise_for_status(self):
            pass

        def json(self):
            return {"meta": {"success": True}, "data": {"records": [{"title": "网上申请"}]}}

    class FakeHttpClient:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            requests.append((endpoint, params))
            return FakeResponse()

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    items = client.get_notice_items(page_size=1)

    assert any(item["title"] == "网上申请" for item in items)
    assert "csrfToken" in requests[0][1]


def test_ehall_client_get_notice_items_paginates(monkeypatch):
    requests = []

    class FakeResponse:
        headers = {"content-type": "application/json"}
        text = ""

        def __init__(self, page_num):
            self.url = "https://ehall.gzus.edu.cn/api/bpm/processes/tasks/apply"
            self.page_num = page_num

        def raise_for_status(self):
            pass

        def json(self):
            if self.page_num == 1:
                return {
                    "meta": {"success": True},
                    "data": {"total": 2, "records": [{"title": "消息一", "taskId": "1"}]},
                }
            return {
                "meta": {"success": True},
                "data": {"total": 2, "records": [{"title": "消息二", "taskId": "2"}]},
            }

    class FakeHttpClient:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            requests.append((endpoint, params))
            return FakeResponse(params["pageNum"])

    monkeypatch.setattr("app.ehall_client.TASK_ENDPOINTS", {"申请": "api/bpm/processes/tasks/apply"})
    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    items = client.get_notice_items(page_size=1, max_pages=5)

    assert [item["title"] for item in items] == ["消息一", "消息二"]
    assert [request[1]["pageNum"] for request in requests] == [1, 2]


def test_ehall_client_get_affairs_paginates(monkeypatch):
    requests = []

    class FakeResponse:
        url = "https://ehall.gzus.edu.cn/api/affair/uis/affairs"
        headers = {"content-type": "application/json"}
        text = ""

        def __init__(self, page_num):
            self.page_num = page_num

        def raise_for_status(self):
            pass

        def json(self):
            if self.page_num == 1:
                return {
                    "meta": {"success": True},
                    "data": {"total": 2, "records": [{"id": "1", "name": "业务一"}]},
                }
            return {
                "meta": {"success": True},
                "data": {"total": 2, "records": [{"id": "2", "name": "业务二"}]},
            }

    class FakeHttpClient:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            requests.append((endpoint, params))
            return FakeResponse(params["pageNum"])

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    items = client.get_affairs(page_size=1, max_pages=5)

    assert [item["title"] for item in items] == ["业务一", "业务二"]
    assert [request[1]["pageNum"] for request in requests] == [1, 2]


def test_ehall_client_get_applications_timeout_raises(monkeypatch):
    requests = []

    class FakeHttpClient:
        is_closed = False

        def __init__(self, **kwargs):
            pass

        def get(self, endpoint, params, timeout=None):
            requests.append((endpoint, params, timeout))
            import httpx

            raise httpx.TimeoutException("slow upstream")

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    with pytest.raises(RuntimeError):
        client.get_applications(page_size=80, max_pages=1, request_timeout_seconds=5)

    assert len(requests) == 1
    assert requests[0][0] == "api/affair/uis/affairs"
    assert requests[0][1]["appStatus"] == 1
    assert requests[0][2] == 5


def test_ehall_client_get_applications_fallback_when_primary_empty(monkeypatch):
    requests = []

    class FakeResponse:
        url = "https://ehall.gzus.edu.cn/api/affair/uis/affairs"
        headers = {"content-type": "application/json"}
        text = ""

        def __init__(self, params):
            self.params = params

        def raise_for_status(self):
            pass

        def json(self):
            if "appStatus" in self.params:
                return {"meta": {"success": True}, "data": {"total": 0, "records": []}}
            return {
                "meta": {"success": True},
                "data": {"total": 1, "records": [{"id": "app-1", "name": "网上申请"}]},
            }

    class FakeHttpClient:
        is_closed = False

        def __init__(self, **kwargs):
            pass

        def get(self, endpoint, params, timeout=None):
            requests.append((endpoint, params, timeout))
            return FakeResponse(params)

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    items = client.get_applications(page_size=80, max_pages=1, request_timeout_seconds=5)

    assert [item["title"] for item in items] == ["网上申请"]
    assert len(requests) == 2
    assert "appStatus" in requests[0][1]
    assert "appStatus" not in requests[1][1]


def test_ehall_client_get_affairs_short_timeout_no_retry(monkeypatch):
    requests = []

    class FakeHttpClient:
        is_closed = False

        def __init__(self, **kwargs):
            pass

        def get(self, endpoint, params, timeout=None):
            requests.append((endpoint, params, timeout))
            import httpx

            raise httpx.TimeoutException("slow upstream")

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    with pytest.raises(RuntimeError):
        client.get_affairs(
            page_size=100,
            max_pages=1,
            request_timeout_seconds=5,
            max_retries=0,
        )

    assert len(requests) == 1
    assert requests[0][0] == "api/affair/uis/affairs"
    assert requests[0][1]["pageSize"] == 100
    assert requests[0][2] == 5


def test_ehall_client_get_progress_overview_includes_category_counts(monkeypatch):
    requests = []

    class FakeResponse:
        headers = {"content-type": "application/json"}
        text = ""

        def __init__(self, endpoint):
            self.url = f"https://ehall.gzus.edu.cn/{endpoint}"
            self.endpoint = endpoint

        def raise_for_status(self):
            pass

        def json(self):
            if self.endpoint.endswith("/apply"):
                return {
                    "meta": {"success": True},
                    "data": {
                        "total": 14,
                        "records": [
                            {
                                "subject": "学生外出申请",
                                "createTime": "2026-06-03 12:00:00",
                                "nodeName": "申请人",
                                "taskId": "task-apply",
                            }
                        ],
                    },
                }
            return {"meta": {"success": True}, "data": {"total": 0, "records": []}}

    class FakeHttpClient:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            requests.append((endpoint, params))
            return FakeResponse(endpoint)

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    overview = client.get_progress_overview(page_size=1)

    counts = {item["label"]: item["count"] for item in overview["categories"]}
    assert counts["待办"] == 0
    assert counts["申请"] == 14
    assert counts["草稿"] == 0
    assert overview["items"][0]["title"] == "学生外出申请"
    assert overview["items"][0]["category"] == "申请"
    assert len(requests) == 7


def test_ehall_client_detects_login_page(monkeypatch):
    class FakeResponse:
        url = "https://cas.gzus.edu.cn/lyuapServer/login"
        headers = {"content-type": "text/html"}
        text = "<input type='password'>"

        def raise_for_status(self):
            pass

        def json(self):
            return {}

    class FakeHttpClient:
        def __init__(self, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            return FakeResponse()

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    with pytest.raises(EhallAuthenticationError):
        client.get_notice_items(page_size=1)


def test_fill_leave_application_uploads_all_attachments(monkeypatch):
    requests = []

    class FakeResponse:
        url = "https://ehall.gzus.edu.cn/bpm/r?wf_num=R_S003_B036"
        headers = {"content-type": "text/html"}

        def __init__(self, text):
            self.text = text

        def raise_for_status(self):
            pass

    class FakeHttpClient:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def get(self, endpoint, params):
            requests.append(("get", endpoint, params))
            return FakeResponse(
                """
                <title>学生课程请假申请(20240319版)</title>
                <input id="WF_DocUnid" value="doc-1">
                <input id="WF_Processid" value="proc-1">
                <input id="WF_CurrentNodeName" value="申请人">
                """
            )

        def post(self, endpoint, params, data, files):
            requests.append(("post", endpoint, params, data, files))
            return FakeResponse("ok")

    monkeypatch.setattr("app.ehall_client.httpx.Client", FakeHttpClient)
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")

    result = client.fill_leave_application(
        start_date=date(2026, 6, 3),
        end_date=date(2026, 6, 3),
        leave_days=1,
        reason="事假",
        courses=[{"teacher": "张老师"}],
        attachments=[("note-a.txt", b"first"), ("note-b.txt", b"second")],
    )

    first_upload = requests[1]
    second_upload = requests[2]
    assert result["status"] == "filled"
    assert result["attachmentUploaded"] is True
    assert result["attachmentUploadedCount"] == 2
    assert result["attachmentTotal"] == 2
    assert first_upload[1] == "bpm/rule"
    assert first_upload[2]["wf_num"] == "R_S004_B002"
    assert first_upload[3]["DocUnid"] == "doc-1"
    assert first_upload[3]["Processid"] == "proc-1"
    assert first_upload[3]["FdName"] == "file1"
    assert first_upload[4]["file"][0] == "note-a.txt"
    assert second_upload[4]["file"][0] == "note-b.txt"


def test_leave_attachment_upload_continues_after_partial_failure(monkeypatch):
    client = EhallClient("https://ehall.gzus.edu.cn", "JSESSIONID=abc")
    uploaded_names = []

    def upload_attachment(**kwargs):
        attachment_name = kwargs["attachment_name"]
        uploaded_names.append(attachment_name)
        return attachment_name != "failed.jpg"

    monkeypatch.setattr(client, "upload_leave_attachment", upload_attachment)
    uploaded_count = client._upload_leave_attachments_from_form(
        '<input id="WF_DocUnid" value="doc-1">',
        attachments=[
            ("first.jpg", b"first"),
            ("failed.jpg", b"failed"),
            ("last.jpg", b"last"),
        ],
    )

    assert uploaded_count == 2
    assert uploaded_names == ["first.jpg", "failed.jpg", "last.jpg"]
