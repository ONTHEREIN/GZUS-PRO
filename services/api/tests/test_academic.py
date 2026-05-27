from fastapi.testclient import TestClient

from app.main import create_app
from app.school_client import AuthenticationError


class FakeClient:
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
        return [{"category": "通知公告", "title": "测试通知", "date": "2026-05-22"}]

    def logout(self):
        pass


class ExpiredClient(FakeClient):
    def get_schedule(self, year, term):
        raise AuthenticationError("教务系统会话已失效，请重新登录")


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


def test_academic_authentication_error_returns_json_401():
    app = create_app()
    session = app.state.sessions.create(ExpiredClient(), "测试学生")
    client = TestClient(app)

    response = client.get("/schedule", headers={"X-Session-Id": session.id})

    assert response.status_code == 401
    assert response.json()["detail"] == "教务系统会话已失效，请重新登录"
