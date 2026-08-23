from fastapi.testclient import TestClient

from app.config import get_settings
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
        }

    def get_schedule(self, year, term):
        return [{"name": "高等数学", "weekday": 1, "startSection": 1, "endSection": 2}]

    def get_exams(self, year, term):
        return [{"courseName": "高等数学", "time": "2026-06-20 09:00", "location": "A101"}]

    def get_grades(self, year, term):
        return [{"courseName": "高等数学", "score": "95", "credit": "4", "gradePoint": "4.5"}]

    def get_attendance(self, year, term):
        return [{"courseName": "高等数学", "normal": 10, "late": 0, "total": 10}]

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


class ExpiredClient(FakeClient):
    def get_schedule(self, year, term):
        raise AuthenticationError("教务系统会话已失效，请重新登录")


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


def test_attendance_and_credits():
    client, headers = client_with_session()
    attendance = client.get("/attendance", headers=headers).json()
    credits = client.get("/credits", headers=headers).json()
    notices = client.get("/notices", headers=headers).json()
    assert attendance["status"] == "ok"
    assert attendance["items"][0]["normal"] == 10
    assert credits[0]["totalCredit"] == "120"
    assert notices[0]["title"] == "测试通知"


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
    assert response.json()["detail"] == "办事大厅数据获取失败，请稍后重试"


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
    assert response.json()["detail"] == "办事大厅数据获取失败，请稍后重试"


def test_academic_authentication_error_returns_json_401():
    app = create_app()
    session = app.state.sessions.create(ExpiredClient(), "测试学生")
    client = TestClient(app)

    response = client.get("/schedule", headers={"X-Session-Id": session.id})

    assert response.status_code == 401
    assert response.json()["detail"] == "教务系统会话已失效，请重新登录"


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


def test_401_not_cached():
    app = create_app()
    with TestClient(app) as client:
        ok_session = app.state.sessions.create(FakeClient(), "测试学生")
        ok_headers = {"X-Session-Id": ok_session.id}

        client.get("/schedule", headers=ok_headers)

        auth_fail_session = app.state.sessions.create(AuthFailClient(), "测试学生")
        auth_headers = {"X-Session-Id": auth_fail_session.id}

        resp = client.get("/schedule", headers=auth_headers)
        assert resp.status_code == 401
