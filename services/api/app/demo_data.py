"""本地宣传演示账号的数据与只读客户端。

该模块只包含虚构数据；演示客户端不创建网络连接，也不读取学校系统配置。
"""
from __future__ import annotations

from typing import Any


DEMO_ACCOUNT = "demo_screenshot_2026"
DEMO_STUDENT_ID = "DEMO-2026-001"
DEMO_STUDENT_NAME = "演示同学"


def is_demo_student(student_id: str | None) -> bool:
    return student_id == DEMO_STUDENT_ID


def demo_ecard_summary() -> dict[str, Any]:
    return {
        "status": "ok",
        "studentId": DEMO_STUDENT_ID,
        "roomId": "DEMO|A1|A1|101",
        "roomDisplay": "演示宿舍 A1-101",
        "powerBalance": 68.4,
        "powerUnit": "度",
        "powerText": "68.4 度",
        "coldWaterBalance": 9.6,
        "coldWaterUnit": "吨",
        "coldWaterText": "9.6 吨",
        "hotWaterBalance": 42.8,
        "hotWaterUnit": "元",
        "hotWaterText": "42.80元",
        "reminderEnabled": True,
        "lowPowerThreshold": 30,
        "lowColdWaterThreshold": 5.0,
        "lowHotWaterThreshold": 10.0,
        "reminderTimes": ["08:00"],
        "reminderItems": ["power", "cold_water", "hot_water"],
        "updatedAt": "2026-09-19T08:00:00+08:00",
        "stale": False,
    }


def demo_ecard_consumption() -> dict[str, Any]:
    return {
        "status": "ok",
        "cachedAt": "2026-09-19T08:00:00+08:00",
        "items": [
            {"title": "宿舍电费", "amount": "-12.40", "time": "08:12", "date": "2026-09-18", "usage": 4.2, "unit": "度"},
            {"title": "宿舍电费", "amount": "-8.70", "time": "19:36", "date": "2026-09-17", "usage": 3.1, "unit": "度"},
            {"title": "宿舍电费", "amount": "-10.20", "time": "12:05", "date": "2026-09-16", "usage": 3.6, "unit": "度"},
        ],
    }


def demo_ecard_overview() -> dict[str, Any]:
    return {
        "status": "ok",
        "months": [
            {
                "month": "2026-09",
                "recordedDays": 19,
                "totalUsage": 42.6,
                "averageDailyUsage": 2.24,
                "peakDate": "2026-09-12",
                "peakUsage": 4.8,
                "unit": "度",
                "cachedAt": "2026-09-19T08:00:00+08:00",
            },
            {
                "month": "2026-08",
                "recordedDays": 22,
                "totalUsage": 51.2,
                "averageDailyUsage": 2.33,
                "peakDate": "2026-08-25",
                "peakUsage": 5.1,
                "unit": "度",
                "cachedAt": "2026-09-01T08:00:00+08:00",
            },
        ],
        "coldWaterMonths": [],
        "hotWaterMonths": [],
    }


class DemoAcademicClient:
    """实现学校客户端读取接口，但所有返回值均来自本地固定 fixture。"""

    _account = DEMO_STUDENT_ID

    def get_info(self) -> dict[str, str]:
        return {
            "studentId": DEMO_STUDENT_ID,
            "name": DEMO_STUDENT_NAME,
            "college": "软件工程学院",
            "major": "软件工程",
            "className": "24软工演示班",
            "grade": "2024",
            "gender": "",
            "enrollDate": "2024-09-01",
            "studentStatus": "在读",
            "educationLevel": "本科",
        }

    def get_schedule(self, year: str | None, term: str | None) -> list[dict[str, object]]:
        return [
            {"name": "软件工程导论", "teacher": "林老师", "classroom": "A3-201", "weekday": 1, "startSection": 1, "endSection": 2, "weeks": "1-16"},
            {"name": "高等数学（下）", "teacher": "周老师", "classroom": "B2-305", "weekday": 1, "startSection": 5, "endSection": 6, "weeks": "1-16"},
            {"name": "数据结构", "teacher": "陈老师", "classroom": "实训楼 204", "weekday": 2, "startSection": 3, "endSection": 4, "weeks": "1-16"},
            {"name": "大学英语（四）", "teacher": "王老师", "classroom": "A1-108", "weekday": 3, "startSection": 1, "endSection": 2, "weeks": "1-16"},
            {"name": "数据库原理", "teacher": "赵老师", "classroom": "A3-302", "weekday": 3, "startSection": 7, "endSection": 8, "weeks": "1-16"},
            {"name": "操作系统", "teacher": "黄老师", "classroom": "B1-204", "weekday": 4, "startSection": 3, "endSection": 4, "weeks": "1-16"},
            {"name": "体育（网球）", "teacher": "何老师", "classroom": "体育馆 2 号场", "weekday": 5, "startSection": 5, "endSection": 6, "weeks": "1-16"},
        ]

    def get_exams(self, year: str | None, term: str | None) -> list[dict[str, str]]:
        return [
            {"courseName": "数据库原理", "date": "2026-12-24", "weekday": "四", "time": "09:00-11:00", "location": "A3-302", "seat": "18", "type": "期末考试", "credit": "3"},
            {"courseName": "操作系统", "date": "2026-12-28", "weekday": "一", "time": "14:00-16:00", "location": "B1-204", "seat": "27", "type": "期末考试", "credit": "3"},
        ]

    def get_grades(self, year: str | None, term: str | None) -> list[dict[str, str]]:
        return [
            {"courseName": "软件工程导论", "score": "92", "credit": "2", "gradePoint": "4.0", "term": "2025-2026-2", "gradeStatus": "正常", "gradePassed": True},
            {"courseName": "数据结构", "score": "89", "credit": "4", "gradePoint": "3.7", "term": "2025-2026-2", "gradeStatus": "正常", "gradePassed": True},
            {"courseName": "大学英语（四）", "score": "88", "credit": "2", "gradePoint": "3.7", "term": "2025-2026-2", "gradeStatus": "正常", "gradePassed": True},
            {"courseName": "数据库原理", "score": "90", "credit": "3", "gradePoint": "4.0", "term": "2025-2026-2", "gradeStatus": "正常", "gradePassed": True},
            {"courseName": "操作系统", "score": "85", "credit": "3", "gradePoint": "3.3", "term": "2025-2026-2", "gradeStatus": "正常", "gradePassed": True},
        ]

    def get_attendance(self, year: str | None, term: str | None) -> list[dict[str, object]]:
        return [
            {"courseId": "demo-data-structures", "courseName": "数据结构", "courseCode": "SE204", "academicYear": "2025-2026", "term": "2", "normal": 16, "late": 0, "leaveEarly": 0, "absent": 0, "leave": 0, "total": 16},
            {"courseId": "demo-database", "courseName": "数据库原理", "courseCode": "SE306", "academicYear": "2025-2026", "term": "2", "normal": 14, "late": 0, "leaveEarly": 0, "absent": 0, "leave": 1, "total": 15},
        ]

    def get_attendance_details(self, year: str | None, term: str | None, course_id: str) -> list[dict[str, str]]:
        return [{"academicYear": "2025-2026", "term": "2", "status": "normal", "statusLabel": "正常", "courseCode": "SE204", "courseName": "数据结构", "classDate": "2026-09-15", "classTime": "08:30-10:05", "sections": "1-2", "studentId": DEMO_STUDENT_ID, "studentName": DEMO_STUDENT_NAME}]

    def get_credits(self) -> list[dict[str, object]]:
        return [{"studentId": DEMO_STUDENT_ID, "name": DEMO_STUDENT_NAME, "college": "软件工程学院", "major": "软件工程", "grade": "2024", "totalCredit": "48", "requiredCredit": "160", "selectedCredit": "12", "requiredExpected": 140, "electiveExpected": 20, "otherExpected": 0, "requiredEarned": 42, "electiveEarned": 8, "otherEarned": 0, "totalExpected": 160, "totalEarned": 50}]

    def get_notices(self) -> list[dict[str, str]]:
        return [
            {"category": "通知公告", "title": "2026 年秋季学期课程提醒", "date": "2026-09-18", "summary": "请关注近期课程安排和考试时间。", "url": "https://demo.local/notices/semester"},
            {"category": "校园活动", "title": "校园创新实践周报名开始", "date": "2026-09-16", "summary": "欢迎同学报名参加创新实践活动。", "url": "https://demo.local/notices/activity"},
            {"category": "教务通知", "title": "关于期末考试安排的说明", "date": "2026-09-12", "summary": "考试安排已更新，请及时查看。", "url": "https://demo.local/notices/exam"},
        ]

    def get_notice_detail(self, url: str) -> dict[str, str]:
        return {"title": "演示通知详情", "date": "2026-09-18", "contentHtml": "<p>这是用于宣传截图的虚构通知内容。</p>", "url": url}

    def get_jwxt_cookies_string(self) -> str:
        return ""

    def logout(self) -> None:
        return None


class DemoEhallClient:
    """演示办事大厅客户端，只提供首页需要的读取接口。"""

    cookie_header = ""
    _auth_token = ""

    def get_notice_items(self) -> list[dict[str, str]]:
        return [{"category": "办事大厅·申请", "title": "校园卡服务已更新", "date": "2026-09-17", "summary": "可在应用中查看常用校园服务。"}]

    def get_affairs(self, **kwargs: object) -> list[dict[str, object]]:
        return [{"id": "demo-affair-1", "title": "学生请假", "department": "学生处", "type": "学生服务", "tags": ["请假", "常用"], "summary": "查看请假办理入口", "url": "https://demo.local/affairs/leave"}]

    def get_applications(self, **kwargs: object) -> list[dict[str, object]]:
        return [{"id": "demo-application-1", "title": "校园卡服务", "department": "信息中心", "type": "生活服务", "tags": ["校园卡"], "summary": "查看校园卡相关服务", "url": "https://demo.local/affairs/card"}]

    def get_progress_overview(self) -> dict[str, object]:
        return {"categories": [{"label": "进行中", "count": 1}, {"label": "已完成", "count": 2}], "items": [{"id": "demo-progress-1", "title": "校园卡服务申请", "category": "校园服务", "status": "processing", "statusLabel": "办理中", "date": "2026-09-18", "summary": "资料审核中", "currentNode": "信息审核", "handler": "信息中心", "progress": 65, "url": "https://demo.local/progress/1"}]}
