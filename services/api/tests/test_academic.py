import time
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.config import get_settings
from app.database import AdminNotice, DataCache, EcardBinding, get_sync_session_factory
from app.main import create_app
from app.school_client import AuthenticationError


class FakeClient:
    _account = "20240001"

    def get_info(self):
        return {
            "studentId": "20240001",
            "name": "测试学生",
            "college": "软件学院",
            "major": "软件工程",
            "className": "24软工1班",
            "grade": "2024",
        }

    def get_schedule(self, year, term):
        return [{"name": "高等数学", "weekday": 1, "startSection": 1, "endSection": 2}]

    def get_exams(self, year, term):
        return [{"courseName": "高等数学", "time": "2026-06-20 09:00", "location": "A101"}]

    def get_grades(self, year, term):
        return [{"courseName": "高等数学", "score": "95", "credit": "4", "gradePoint": "4.5"}]

    def get_attendance(self, year, term):
        return [
            {
                "courseId": "course-1",
                "courseName": "高等数学",
                "normal": 10,
                "late": 0,
                "total": 10,
            }
        ]

    def get_attendance_details(self, year, term, course_id):
        if course_id != "course-1":
            from app.school_client import AttendanceCourseNotFoundError

            raise AttendanceCourseNotFoundError("当前学期未找到该考勤课程")
        return [
            {
                "academicYear": "2025-2026",
                "term": "1",
                "status": "normal",
                "statusLabel": "正常",
                "courseCode": "GE1030",
                "courseName": "高等数学",
                "classDate": "2025-10-22",
                "classTime": "10:40-12:00",
                "sections": "3-4",
                "studentId": "20250001",
                "studentName": "测试学生",
            }
        ]

    def get_credits(self):
        return [{"studentId": "20240001", "name": "测试学生", "totalCredit": "120"}]

    def get_notices(self):
        return getattr(
            self,
            "notices",
            [{"category": "通知公告", "title": "测试通知", "date": "2026-05-22"}],
        )

    def get_notice_detail(self, url):
        return {"title": "测试通知详情", "date": "2026-05-22", "contentHtml": "<p>正文内容</p>", "url": url}

    def logout(self):
        pass


class CountingInfoClient(FakeClient):
    def __init__(self):
        self.info_calls = 0

    def get_info(self):
        self.info_calls += 1
        return super().get_info()


class IncompleteInfoClient(FakeClient):
    def get_info(self):
        return {"studentId": "20240001", "name": "测试学生"}


class ExpiredClient(FakeClient):
    def get_schedule(self, year, term):
        raise AuthenticationError("登录状态已失效，请重新登录")


class GradeSessionExpiredClient(FakeClient):
    def get_grades(self, year, term):
        raise AuthenticationError("登录状态已失效，请重新登录")


class SlowDashboardClient(FakeClient):
    def get_info(self):
        time.sleep(0.2)
        return super().get_info()

    def get_schedule(self, year, term):
        time.sleep(0.2)
        return super().get_schedule(year, term)

    def get_exams(self, year, term):
        time.sleep(0.2)
        return super().get_exams(year, term)

    def get_grades(self, year, term):
        time.sleep(0.2)
        return super().get_grades(year, term)

    def get_attendance(self, year, term):
        time.sleep(0.2)
        return super().get_attendance(year, term)

    def get_credits(self):
        time.sleep(0.2)
        return super().get_credits()

    def get_notices(self):
        time.sleep(0.2)
        return super().get_notices()


class TimedOutScheduleClient(FakeClient):
    def get_schedule(self, year, term):
        time.sleep(0.1)
        return super().get_schedule(year, term)


class FakeEhallClient:
    def get_notice_items(self):
        return [
            {
                "category": "办事大厅·申请",
                "title": "网上申请",
                "date": "2026-06-01",
                "summary": "待提交",
            }
        ]

    def get_affairs(self, **kwargs):
        return [
            {
                "id": "affair-1",
                "title": "学生请假",
                "department": "学生处",
                "type": "学生服务",
                "tags": ["请假"],
                "url": "https://ehall.gzus.edu.cn/#/affairs/copyAllAffairs/guide/affair-1?id=bsdt",
            }
        ]

    def get_applications(self, **kwargs):
        return [
            {
                "id": "app-1",
                "title": "网上申请",
                "department": "信息中心",
                "type": "服务",
                "tags": ["申请"],
                "url": "https://ehall.gzus.edu.cn/#/affairs/copyAllAffairs/guide/app-1?id=yyzx",
            }
        ]


class BrokenEhallClient:
    def get_affairs(self, **kwargs):
        raise RuntimeError("slow upstream")

    def get_applications(self, **kwargs):
        raise RuntimeError("slow upstream")


def client_with_session():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")
    client = TestClient(app)
    return client, {"X-Session-Id": session.id}


def test_requires_session():
    app = create_app()
    client = TestClient(app)
    response = client.get("/me")
    assert response.status_code == 401


def test_me_schedule_exams_grades():
    client, headers = client_with_session()

    assert client.get("/me", headers=headers).json()["name"] == "测试学生"
    assert client.get("/schedule", headers=headers).json()[0]["name"] == "高等数学"
    assert client.get("/exams", headers=headers).json()[0]["courseName"] == "高等数学"
    assert client.get("/grades", headers=headers).json()[0]["score"] == "95"


def test_me_uses_server_cache_for_repeated_requests():
    app = create_app()
    info_client = CountingInfoClient()
    session = app.state.sessions.create(info_client, "测试学生")
    headers = {"X-Session-Id": session.id}

    with TestClient(app) as client:
        first_response = client.get("/me", headers=headers)
        cached_response = client.get("/me", headers=headers)

    assert first_response.status_code == 200
    assert cached_response.status_code == 200
    assert cached_response.headers["X-Data-Source"] == "cache"
    assert info_client.info_calls == 1


def test_attendance_and_credits():
    client, headers = client_with_session()
    attendance = client.get("/attendance", headers=headers).json()
    credits = client.get("/credits", headers=headers).json()
    notices = client.get("/notices", headers=headers).json()
    assert attendance["status"] == "ok"
    assert attendance["items"][0]["normal"] == 10
    assert attendance["items"][0]["courseId"] == "course-1"
    assert credits[0]["totalCredit"] == "120"
    assert notices[0]["title"] == "测试通知"


def test_attendance_details_are_course_scoped_and_authenticated():
    client, headers = client_with_session()

    response = client.get(
        "/attendance/details?year=2025&term=1&courseId=course-1", headers=headers
    )

    assert response.status_code == 200
    detail = response.json()["items"][0]
    assert detail["courseCode"] == "GE1030"
    assert detail["classDate"] == "2025-10-22"
    assert client.get("/attendance/details?courseId=course-1").status_code == 401
    assert (
        client.get("/attendance/details?year=2025&term=1&courseId=missing", headers=headers)
        .status_code
        == 404
    )


def test_dashboard_runs_modules_in_parallel():
    app = create_app()
    session = app.state.sessions.create(SlowDashboardClient(), "测试学生")
    client = TestClient(app)

    started = time.monotonic()
    response = client.get("/dashboard?year=2025&term=2&week=3", headers={"X-Session-Id": session.id})
    duration = time.monotonic() - started

    assert response.status_code == 200
    assert duration < 0.8
    assert response.json()["modules"]["schedule"]["status"] == "ok"


def test_dashboard_can_load_only_requested_modules():
    client, headers = client_with_session()

    response = client.get(
        "/dashboard?year=2025&term=2&modules=me,schedule,grades",
        headers=headers,
    )

    assert response.status_code == 200
    assert set(response.json()["modules"]) == {"me", "schedule", "grades"}


def test_dashboard_marks_module_authentication_failure_for_relogin():
    app = create_app()
    session = app.state.sessions.create(GradeSessionExpiredClient(), "测试学生")
    client = TestClient(app)

    response = client.get(
        "/dashboard?year=2025&term=2&modules=schedule,grades",
        headers={"X-Session-Id": session.id},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["needsRelogin"] is True
    assert payload["modules"]["schedule"]["status"] == "ok"
    assert payload["modules"]["grades"]["status"] == "error"
    assert payload["modules"]["grades"]["needsRelogin"] is True


def test_widget_snapshot_is_authenticated_compact_and_etagged():
    client, headers = client_with_session()

    assert client.get("/widget-snapshot?year=2025&term=2").status_code == 401
    first = client.get("/widget-snapshot?year=2025&term=2", headers=headers)

    assert first.status_code == 200
    assert set(first.json()["modules"]) == {
        "schedule",
        "grades",
        "exams",
        "progress",
        "ecard",
    }
    assert "jwxtCookies" not in first.text
    assert "ehallCookies" not in first.text
    etag = first.headers["etag"]
    second = client.get(
        "/widget-snapshot?year=2025&term=2",
        headers={**headers, "If-None-Match": etag},
    )
    assert second.status_code == 304


def test_dashboard_returns_cached_ecard_summary_for_bound_room():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")
    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            EcardBinding(
                student_id="20240001",
                room_id="CGCOMMON1111|1|A2|932",
                room_display="校本部 A2 A2-932",
                last_summary_json=(
                    '{"powerBalance": 12.5, "powerText": "12.5 度", '
                    '"coldWaterBalance": 3.2, "coldWaterText": "3.2 吨"}'
                ),
                hot_water_balance_cache=6.8,
            )
        )
        db.commit()

    response = TestClient(app).get(
        "/dashboard?year=2025&term=2&week=3",
        headers={"X-Session-Id": session.id},
    )

    assert response.status_code == 200
    ecard = response.json()["modules"]["ecard"]
    assert ecard["status"] == "ok"
    assert ecard["source"] == "cache"
    assert ecard["data"]["roomDisplay"] == "校本部 A2 A2-932"
    assert ecard["data"]["powerText"] == "12.5 度"
    assert ecard["data"]["coldWaterText"] == "3.2 吨"
    assert ecard["data"]["hotWaterText"] == "6.80元"


def test_dashboard_returns_not_bound_ecard_summary_without_binding():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")

    response = TestClient(app).get(
        "/dashboard?year=2025&term=2&week=3",
        headers={"X-Session-Id": session.id},
    )

    ecard = response.json()["modules"]["ecard"]
    assert ecard["status"] == "empty"
    assert ecard["data"] == {"status": "not_bound"}


def test_dashboard_returns_module_error_before_client_timeout(monkeypatch):
    monkeypatch.setattr("app.routes.academic._DASHBOARD_MODULE_TIMEOUT_SECONDS", 0.01)
    app = create_app()
    session = app.state.sessions.create(TimedOutScheduleClient(), "测试学生")
    client = TestClient(app)

    response = client.get("/dashboard?year=2025&term=2&week=3", headers={"X-Session-Id": session.id})

    assert response.status_code == 200
    schedule = response.json()["modules"]["schedule"]
    assert schedule["status"] == "error"
    assert schedule["error"] == "课表模块加载超过 0.01 秒，请稍后重试"


def test_notices_merge_ehall_tasks():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=FakeEhallClient(),
    )
    client = TestClient(app)

    notices = client.get("/notices", headers={"X-Session-Id": session.id}).json()

    assert [item["title"] for item in notices] == ["测试通知", "网上申请"]
    assert notices[1]["category"] == "办事大厅·申请"


def test_notices_filter_garbled_items():
    app = create_app()
    client = TestClient(app)
    session = app.state.sessions.create(FakeClient(), "测试学生")
    session.client.notices = [
        {"category": "通知公告", "title": "æ–°é€šçŸ¥", "url": "/bad"},
        {"category": "通知公告", "title": "正常通知", "url": "/ok"},
    ]

    notices = client.get("/notices", headers={"X-Session-Id": session.id}).json()

    assert [item["title"] for item in notices] == ["正常通知"]


def test_ehall_tasks_route_returns_ehall_items():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=FakeEhallClient(),
    )
    client = TestClient(app)

    tasks = client.get("/ehall/tasks", headers={"X-Session-Id": session.id}).json()

    assert tasks[0]["title"] == "网上申请"


def test_ehall_affairs_route_returns_business_items():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=FakeEhallClient(),
    )
    client = TestClient(app)

    affairs = client.get("/ehall/affairs", headers={"X-Session-Id": session.id}).json()

    assert affairs[0]["title"] == "学生请假"
    assert affairs[0]["department"] == "学生处"


def test_ehall_applications_route_returns_application_items():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=FakeEhallClient(),
    )
    client = TestClient(app)

    applications = client.get("/ehall/applications", headers={"X-Session-Id": session.id}).json()

    assert applications[0]["title"] == "网上申请"
    assert applications[0]["department"] == "信息中心"


def test_ehall_affairs_route_returns_504_when_upstream_fails():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=BrokenEhallClient(),
    )
    client = TestClient(app)

    response = client.get("/ehall/affairs", headers={"X-Session-Id": session.id})

    assert response.status_code == 504
    assert response.json()["detail"] == "办事大厅请求失败（未返回可用数据），请稍后重试"


def test_ehall_applications_route_returns_504_when_upstream_fails():
    app = create_app()
    session = app.state.sessions.create(
        FakeClient(),
        "测试学生",
        ehall_client=BrokenEhallClient(),
    )
    client = TestClient(app)

    response = client.get("/ehall/applications", headers={"X-Session-Id": session.id})

    assert response.status_code == 504
    assert response.json()["detail"] == "办事大厅请求失败（未返回可用数据），请稍后重试"


def test_academic_authentication_error_returns_json_401():
    app = create_app()
    session = app.state.sessions.create(ExpiredClient(), "测试学生")
    client = TestClient(app)

    response = client.get("/schedule", headers={"X-Session-Id": session.id})

    assert response.status_code == 401
    assert response.json()["detail"] == "登录状态已失效，请重新登录"


def test_incomplete_student_info_is_not_cached_as_success():
    app = create_app()
    session = app.state.sessions.create(IncompleteInfoClient(), "测试学生")
    headers = {"X-Session-Id": session.id}

    with TestClient(app) as client:
        response = client.get("/me", headers=headers)

    assert response.status_code == 502
    assert response.json()["detail"] == "学校教务系统返回的个人信息不完整，请稍后重试"
    with get_sync_session_factory()() as db:
        assert db.query(DataCache).filter(DataCache.resource == "me").count() == 0


def test_notice_detail_route():
    client, headers = client_with_session()
    url = f"{get_settings().jw_base_url}/notice/1.html"
    response = client.get(
        f"/notices/detail?url={url}",
        headers=headers,
    )
    assert response.status_code == 200
    data = response.json()
    assert data["title"] == "测试通知详情"
    assert data["contentHtml"] == "<p>正文内容</p>"
    assert data["url"] == url


class FailingClient(FakeClient):
    def get_info(self):
        raise RuntimeError("学校系统 502")

    def get_schedule(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_exams(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_grades(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_attendance(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_credits(self):
        raise RuntimeError("学校系统 502")

    def get_notices(self):
        raise RuntimeError("学校系统 502")

    def get_notice_detail(self, url):
        raise RuntimeError("学校系统 502")


class AuthFailClient(FakeClient):
    def get_schedule(self, year, term):
        raise AuthenticationError("会话已失效")

    def get_exams(self, year, term):
        raise AuthenticationError("会话已失效")

    def get_attendance(self, year, term):
        raise AuthenticationError("会话已失效")


def test_cache_fallback_on_502():
    app = create_app()
    with TestClient(app) as client:
        ok_session = app.state.sessions.create(FakeClient(), "测试学生")
        headers = {"X-Session-Id": ok_session.id}

        client.get("/me", headers=headers)
        client.get("/schedule", headers=headers)
        client.get("/credits", headers=headers)

        fail_session = app.state.sessions.create(FailingClient(), "测试学生")
        fail_headers = {"X-Session-Id": fail_session.id}

        me_resp = client.get("/me", headers=fail_headers)
        assert me_resp.status_code == 200
        assert me_resp.headers.get("X-Data-Source") == "cache"
        assert me_resp.json()["name"] == "测试学生"

        schedule_resp = client.get("/schedule", headers=fail_headers)
        assert schedule_resp.status_code == 200
        assert schedule_resp.headers.get("X-Data-Source") == "cache"
        assert schedule_resp.json()[0]["name"] == "高等数学"

        credits_resp = client.get("/credits", headers=fail_headers)
        assert credits_resp.status_code == 200
        assert credits_resp.headers.get("X-Data-Source") == "cache"
        assert credits_resp.json()[0]["totalCredit"] == "120"


def test_academic_cache_fallback_on_school_session_expiry():
    app = create_app()
    with TestClient(app) as client:
        ok_session = app.state.sessions.create(FakeClient(), "测试学生")
        headers = {"X-Session-Id": ok_session.id}
        assert client.get("/exams?year=2025&term=1", headers=headers).status_code == 200
        assert client.get("/attendance?year=2025&term=1", headers=headers).status_code == 200

        expired_session = app.state.sessions.create(AuthFailClient(), "测试学生")
        expired_headers = {"X-Session-Id": expired_session.id}
        exams_response = client.get("/exams?year=2025&term=1", headers=expired_headers)
        attendance_response = client.get(
            "/attendance?year=2025&term=1", headers=expired_headers
        )

        assert exams_response.status_code == 200
        assert exams_response.headers["X-Data-Source"] == "cache"
        assert exams_response.json()[0]["courseName"] == "高等数学"
        assert attendance_response.status_code == 200
        assert attendance_response.headers["X-Data-Source"] == "cache"
        assert attendance_response.json()["items"][0]["courseName"] == "高等数学"


def test_academic_cache_expires_after_one_semester():
    app = create_app()
    with TestClient(app) as client:
        ok_session = app.state.sessions.create(FakeClient(), "测试学生")
        headers = {"X-Session-Id": ok_session.id}
        assert client.get("/exams?year=2025&term=1", headers=headers).status_code == 200

        Session = get_sync_session_factory()
        with Session() as database_session:
            entry = database_session.query(DataCache).one()
            entry.cached_at = datetime.now(timezone.utc) - timedelta(days=181)
            database_session.commit()

        expired_session = app.state.sessions.create(AuthFailClient(), "测试学生")
        response = client.get(
            "/exams?year=2025&term=1",
            headers={"X-Session-Id": expired_session.id},
        )

        assert response.status_code == 401


class FailingClientNoAccount(FakeClient):
    _account = "99999999"

    def get_info(self):
        raise RuntimeError("学校系统 502")

    def get_schedule(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_exams(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_grades(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_attendance(self, year, term):
        raise RuntimeError("学校系统 502")

    def get_credits(self):
        raise RuntimeError("学校系统 502")

    def get_notices(self):
        raise RuntimeError("学校系统 502")

    def get_notice_detail(self, url):
        raise RuntimeError("学校系统 502")


def test_no_cache_returns_502():
    app = create_app()
    with TestClient(app) as client:
        fail_session = app.state.sessions.create(FailingClientNoAccount(), "测试学生")
        headers = {"X-Session-Id": fail_session.id}

        resp = client.get("/me", headers=headers)
        assert resp.status_code == 502
        assert resp.json()["detail"] == "学校教务系统暂时不可用（上游 HTTP 502），请稍后重试"


def test_force_refresh_does_not_mask_authentication_error():
    app = create_app()
    with TestClient(app) as client:
        ok_session = app.state.sessions.create(FakeClient(), "测试学生")
        ok_headers = {"X-Session-Id": ok_session.id}

        client.get("/schedule", headers=ok_headers)

        auth_fail_session = app.state.sessions.create(AuthFailClient(), "测试学生")
        auth_headers = {"X-Session-Id": auth_fail_session.id}

        resp = client.get("/schedule?refresh=true", headers=auth_headers)
        assert resp.status_code == 401


class CountingClient(FakeClient):
    def __init__(self):
        self.schedule_calls = 0
        self.grade_calls = 0
        self.notice_calls = 0

    def get_schedule(self, year, term):
        self.schedule_calls += 1
        return super().get_schedule(year, term)

    def get_grades(self, year, term):
        self.grade_calls += 1
        return super().get_grades(year, term)

    def get_notices(self):
        self.notice_calls += 1
        return super().get_notices()


def test_fresh_cache_avoids_repeat_school_requests():
    app = create_app()
    upstream = CountingClient()
    session = app.state.sessions.create(upstream, "测试学生")
    headers = {"X-Session-Id": session.id}
    client = TestClient(app)

    client.get("/schedule?year=2025&term=2", headers=headers)
    cached_schedule = client.get("/schedule?year=2025&term=2", headers=headers)
    client.get("/grades?year=2025&term=2", headers=headers)
    cached_grades = client.get("/grades?year=2025&term=2", headers=headers)
    client.get("/notices", headers=headers)
    cached_notices = client.get("/notices", headers=headers)

    assert upstream.schedule_calls == 1
    assert upstream.grade_calls == 1
    assert upstream.notice_calls == 1
    assert cached_schedule.headers["X-Data-Source"] == "cache"
    assert cached_schedule.headers["X-Data-Cached-At"]
    assert cached_grades.headers["X-Data-Source"] == "cache"
    assert cached_notices.headers["X-Data-Source"] == "cache"


def test_public_notices_are_merged_after_student_notice_cache():
    app = create_app()
    session = app.state.sessions.create(FakeClient(), "测试学生")
    headers = {"X-Session-Id": session.id}
    client = TestClient(app)

    first = client.get("/notices", headers=headers)
    assert [item["title"] for item in first.json()] == ["测试通知"]

    factory = get_sync_session_factory()
    with factory() as db:
        db.add(
            AdminNotice(
                title="2026-2027 学年校历",
                description="管理员发布的校历",
                published=True,
                is_pinned=True,
            )
        )
        db.commit()

    cached = client.get("/notices", headers=headers)
    items = cached.json()
    assert cached.headers["X-Data-Source"] == "cache"
    assert items[0]["title"] == "2026-2027 学年校历"
    assert items[0]["source"] == "admin"

    dashboard = client.get("/dashboard?year=2025&term=2&week=3", headers=headers)
    dashboard_items = dashboard.json()["modules"]["notices"]["data"]
    assert dashboard_items[0]["title"] == "2026-2027 学年校历"

    with factory() as db:
        row = db.query(AdminNotice).filter(AdminNotice.title == "2026-2027 学年校历").first()
        row.published = False
        db.commit()

    after_unpublish = client.get("/notices", headers=headers).json()
    assert [item["title"] for item in after_unpublish] == ["测试通知"]


def test_dashboard_reuses_fresh_module_caches_and_refreshes_on_demand():
    app = create_app()
    upstream = CountingClient()
    session = app.state.sessions.create(upstream, "测试学生")
    headers = {"X-Session-Id": session.id}
    client = TestClient(app)

    client.get("/dashboard?year=2025&term=2&week=3", headers=headers)
    cached = client.get("/dashboard?year=2025&term=2&week=3", headers=headers)

    assert upstream.schedule_calls == 1
    assert upstream.grade_calls == 1
    assert upstream.notice_calls == 1
    assert cached.json()["modules"]["schedule"]["source"] == "cache"

    client.get("/dashboard?year=2025&term=2&week=3&refresh=true", headers=headers)
    assert upstream.schedule_calls == 2
    assert upstream.grade_calls == 2
    assert upstream.notice_calls == 2
