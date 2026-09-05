from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from app.leave_service import (
    build_leave_fill_script,
    build_leave_handler_script,
    build_leave_preview,
    default_first_week_start,
    week_spec_contains,
)
from app.main import create_app
from app.routes.ehall import _decode_leave_attachments
from app.schemas import LEAVE_ATTACHMENT_MAX_COUNT, LeaveAttachmentItem, LeaveFillRequest
from app.staff_service import import_staff_records


class FakeClient:
    def get_schedule(self, year, term):
        return [
            {
                "name": "移动应用开发",
                "teacher": "张老师",
                "weekday": 1,
                "startSection": 1,
                "endSection": 2,
                "weeks": "1-16",
                "raw": {
                    "kch": "CS101",
                    "jxbmc": "JXBMC001",
                    "jxbdm": "JXBDM_SHOULD_NOT_USE",
                    "kcxz": "必修",
                    "xf": "3",
                },
            },
            {
                "name": "数据库",
                "teacher": "李老师",
                "weekday": 3,
                "startSection": 3,
                "endSection": 4,
                "weeks": "1-16",
                "raw": {"kch": "CS102"},
            },
        ]

    def logout(self):
        pass


class FakeEhallClient:
    def __init__(self):
        self.calls = []
        self.upload_calls = []
        self.cookie_header = "JSESSIONID=fake"

    def leave_application_url(self):
        return "https://ehall.gzus.edu.cn/bpm/r?wf_num=R_S003_B036"

    def upload_leave_attachment(self, **kwargs):
        self.upload_calls.append(kwargs)
        return True

    def search_staff(self, keyword):
        if keyword != "张老师":
            return []
        return [
            {
                "JobTitle": "教职工",
                "Userid": "teacher-1",
                "CnName": "张老师",
                "FolderName": "软件与人工智能学院",
            },
            {
                "JobTitle": "学生",
                "Userid": "student-1",
                "CnName": "张同学",
                "FolderName": "测试班级",
            },
        ]


class UnknownTeacherClient:
    def get_schedule(self, year, term):
        return [
            {
                "name": "编译原理",
                "teacher": "王未知",
                "weekday": 1,
                "startSection": 1,
                "endSection": 2,
                "weeks": "1-16",
                "raw": {
                    "kch": "CS201",
                    "jxbdm": "JXB201",
                    "kcxz": "必修",
                    "xf": "3",
                },
            }
        ]

    def logout(self):
        pass


class FailingScheduleClient:
    def get_schedule(self, year, term):
        raise RuntimeError("jwxt timeout")

    def logout(self):
        pass


def test_week_spec_contains_ranges_and_parity():
    assert week_spec_contains("1-16周", 8)
    assert week_spec_contains("1-15单周", 7)
    assert not week_spec_contains("1-15单周", 8)
    assert week_spec_contains("", 20)


def test_build_leave_preview_matches_courses_and_missing_fields():
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)

    preview = build_leave_preview(
        FakeClient().get_schedule("2026", "2"),
        start_date=monday,
        end_date=monday,
        year=2026,
        term=2,
        first_week_start=first_week,
    )

    assert preview["hasMissingFields"] is False
    assert preview["items"][0]["courseName"] == "移动应用开发"
    assert preview["items"][0]["absenceCount"] == 1
    assert preview["items"][0]["courseCode"] == "CS101"


def test_build_leave_preview_flags_missing_required_course_fields():
    first_week = default_first_week_start(2026, 2)
    wednesday = first_week + timedelta(days=9)

    preview = build_leave_preview(
        FakeClient().get_schedule("2026", "2"),
        start_date=wednesday,
        end_date=wednesday,
        year=2026,
        term=2,
        first_week_start=first_week,
    )

    assert preview["hasMissingFields"] is True
    assert "班级编号" in preview["items"][0]["missingFields"]


def test_leave_preview_normalizes_raw_payload_courses():
    app = create_app()
    session = app.state.sessions.create(FailingScheduleClient(), "测试学生")
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)

    response = client.post(
        "/ehall/leave/preview",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
            "courses": [
                {
                    "kcmc": "移动应用开发",
                    "xqj": 1,
                    "jcs": "1-2",
                    "zcd": "1-16周",
                }
            ],
        },
    )

    assert response.status_code == 200
    assert response.json()["items"][0]["courseName"] == "移动应用开发"


def test_decode_leave_attachments_enforces_total_size(monkeypatch):
    monkeypatch.setattr("app.routes.ehall.LEAVE_ATTACHMENT_MAX_BYTES", 2)
    attachments = [
        LeaveAttachmentItem(attachmentName="one.jpg", attachmentContentBase64="YQ=="),
        LeaveAttachmentItem(attachmentName="two.jpg", attachmentContentBase64="Yg=="),
    ]

    assert _decode_leave_attachments(attachments) == [("one.jpg", b"a"), ("two.jpg", b"b")]

    with pytest.raises(ValueError, match="图片总大小"):
        _decode_leave_attachments(
            attachments
            + [LeaveAttachmentItem(attachmentName="three.jpg", attachmentContentBase64="Yw==")]
        )

    with pytest.raises(ValueError):
        _decode_leave_attachments(
            [LeaveAttachmentItem(attachmentName="invalid.jpg", attachmentContentBase64="not-base64")]
        )


def test_leave_fill_request_limits_attachment_count():
    attachment = {"attachmentName": "note.jpg", "attachmentContentBase64": "YQ=="}

    with pytest.raises(ValueError, match="at most 5 items"):
        LeaveFillRequest(
            year=2026,
            term=2,
            startDate="2027-03-08",
            endDate="2027-03-08",
            reason="事假",
            attachments=[attachment] * (LEAVE_ATTACHMENT_MAX_COUNT + 1),
        )


def test_build_leave_fill_script_targets_real_ehall_fields():
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)
    preview = build_leave_preview(
        FakeClient().get_schedule("2026", "2"),
        start_date=monday,
        end_date=monday,
        year=2026,
        term=2,
        first_week_start=first_week,
    )

    script = build_leave_fill_script(
        start_date=monday,
        end_date=monday,
        reason="事假",
        courses=preview["items"],
    )

    assert "setField('KSSJ'" in script
    assert "setField('JSSJ'" in script
    assert "setField('QJTS'" in script
    assert "setField('QJLY'" in script
    assert "'KCMC', '课程名称'" in script
    assert "'KCDM', '课程代码'" in script
    assert "'JXBDM', '班级编号'" in script
    assert "JXBMC001" in script
    assert "JXBDM_SHOULD_NOT_USE" not in script
    assert "'KCXZ', '课程性质'" in script
    assert "'SKSJ', '上课时间'" in script
    assert "_dt_${index}" in script
    assert "WF_NextNodeSelect_T10004" in script


def test_build_leave_handler_script_targets_teacher_handler_fields():
    script = build_leave_handler_script(
        [
            {
                "userid": "u100",
                "cnName": "张老师",
                "teacher": "张老师",
                "courseName": "移动应用开发",
            }
        ]
    )

    assert "WF_NextNodeSelect_T10004" in script
    assert "WF_T10004" in script
    assert "WF_NodeOption_T10004" in script
    assert "u100" in script
    assert "张老师" in script


def test_leave_preview_route_returns_matches():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)

    response = client.post(
        "/ehall/leave/preview",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
        },
    )

    assert response.status_code == 200
    assert response.json()["items"][0]["teacher"] == "张老师"


def test_leave_preview_uses_payload_courses_when_schedule_fetch_fails():
    app = create_app()
    session = app.state.sessions.create(FailingScheduleClient(), "测试学生")
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)

    response = client.post(
        "/ehall/leave/preview",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
            "courses": FakeClient().get_schedule("2026", "2"),
        },
    )

    assert response.status_code == 200
    assert response.json()["items"][0]["courseName"] == "移动应用开发"


def test_leave_preview_falls_back_to_cached_schedule():
    app = create_app()
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)
    ok_session = app.state.sessions.create(FakeClient(), "测试学生")
    fail_session = app.state.sessions.create(FailingScheduleClient(), "测试学生")

    client.get(
        "/schedule",
        headers={"X-Session-Id": ok_session.id},
        params={"year": "2026", "term": "2"},
    )
    response = client.post(
        "/ehall/leave/preview",
        headers={"X-Session-Id": fail_session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
        },
    )

    assert response.status_code == 200
    assert response.json()["items"][0]["teacher"] == "张老师"


def test_leave_fill_requires_ehall_session():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")
    client = TestClient(app)

    response = client.post(
        "/ehall/leave/fill",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": "2026-03-09",
            "endDate": "2026-03-09",
            "reason": "事假",
            "attachmentName": "note.txt",
            "attachmentContentBase64": "b2s=",
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "no_ehall_session"


def test_leave_teacher_search_reads_live_ehall_directory():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(), "测试学生", ehall_client=FakeEhallClient()
    )
    client = TestClient(app)

    response = client.get(
        "/ehall/leave/teachers/search?keyword=%E5%BC%A0%E8%80%81%E5%B8%88",
        headers={"X-Session-Id": session.id},
    )

    assert response.status_code == 200
    assert response.json() == {
        "items": [
            {
                "userid": "teacher-1",
                "cnName": "张老师",
                "folderName": "软件与人工智能学院",
            }
        ]
    }


def test_leave_fill_calls_ehall_client_when_ready():
    ehall = FakeEhallClient()
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生", ehall_client=ehall)
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)
    import_staff_records(
        [
            {
                "JobTitle": "教职工",
                "Userid": "u100",
                "CnName": "张老师",
                "FolderName": "网络空间安全学院",
            }
        ]
    )

    response = client.post(
        "/ehall/leave/fill",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
            "reason": "事假",
            "attachmentName": "note.txt",
            "attachmentContentBase64": "b2s=",
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "filled"
    assert "fillScript" in response.json()
    assert "handlerScript" in response.json()
    assert "'KCMC', '课程名称'" in response.json()["fillScript"]
    assert "WF_T10004" in response.json()["handlerScript"]
    assert response.json()["matchedTeachers"][0]["userid"] == "u100"
    assert response.json()["attachmentUploaded"] is False
    assert response.json()["attachmentUploadedCount"] == 0
    assert response.json()["attachmentTotal"] == 1
    assert ehall.calls == []


def test_leave_fill_uses_manual_teacher_handler_selection():
    ehall = FakeEhallClient()
    app = create_app()
    session = app.state.sessions.create(
        UnknownTeacherClient(), "测试学生", ehall_client=ehall
    )
    client = TestClient(app)
    first_week = default_first_week_start(2026, 2)
    monday = first_week + timedelta(days=7)

    response = client.post(
        "/ehall/leave/fill",
        headers={"X-Session-Id": session.id},
        json={
            "year": 2026,
            "term": 2,
            "startDate": monday.isoformat(),
            "endDate": monday.isoformat(),
            "firstWeekStart": first_week.isoformat(),
            "reason": "事假",
            "attachmentName": "note.txt",
            "attachmentContentBase64": "b2s=",
            "teacherHandlers": [
                {
                    "teacher": "王未知",
                    "userid": "manual1",
                    "cnName": "王老师",
                }
            ],
        },
    )

    body = response.json()
    assert response.status_code == 200
    assert body["status"] == "filled"
    assert body["unmatchedTeachers"] == []
    assert body["matchedTeachers"][0]["userid"] == "manual1"
    assert "manual1" in body["handlerScript"]


def test_leave_attachment_uses_current_page_metadata():
    ehall = FakeEhallClient()
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生", ehall_client=ehall)
    client = TestClient(app)

    response = client.post(
        "/ehall/leave/attachment",
        headers={"X-Session-Id": session.id},
        json={
            "docUnid": "current-doc-1",
            "processId": "current-process-1",
            "nodeName": "当前申请人",
            "localStore": "0",
            "attachmentName": "proof.jpg",
            "attachmentContentBase64": "aW1hZ2U=",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "uploaded": True}
    assert ehall.upload_calls == [
        {
            "doc_unid": "current-doc-1",
            "process_id": "current-process-1",
            "node_name": "当前申请人",
            "local_store": "0",
            "attachment_name": "proof.jpg",
            "attachment_content": b"image",
        }
    ]
