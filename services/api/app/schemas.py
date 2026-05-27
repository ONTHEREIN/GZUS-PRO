from typing import Literal

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    account: str = Field(min_length=1)
    password: str = Field(min_length=1)


class CaptchaRequest(BaseModel):
    captcha_token: str = Field(alias="captchaToken", min_length=1)
    code: str = Field(min_length=1)


class SsoCompleteRequest(BaseModel):
    sso_code: str = Field(alias="ssoCode", min_length=1)


class MobileCookieLoginRequest(BaseModel):
    account: str = Field(min_length=1)
    cookies: str = Field(min_length=1)


class AuthResponse(BaseModel):
    status: Literal["ok", "captcha_required"]
    session_id: str | None = Field(default=None, alias="sessionId")
    student_name: str | None = Field(default=None, alias="studentName")
    captcha_token: str | None = Field(default=None, alias="captchaToken")
    captcha_image: str | None = Field(default=None, alias="captchaImage")


class StudentInfo(BaseModel):
    student_id: str = Field(alias="studentId")
    name: str
    college: str | None = None
    major: str | None = None
    class_name: str | None = Field(default=None, alias="className")
    grade: str | None = None
    photo_data_url: str | None = Field(default=None, alias="photoDataUrl")


class ScheduleCourse(BaseModel):
    name: str
    teacher: str | None = None
    classroom: str | None = None
    weekday: int | None = None
    start_section: int | None = Field(default=None, alias="startSection")
    end_section: int | None = Field(default=None, alias="endSection")
    weeks: str | None = None
    raw: dict | None = None


class ExamItem(BaseModel):
    course_name: str = Field(alias="courseName")
    time: str | None = None
    location: str | None = None
    seat: str | None = None
    type: str | None = None
    credit: str | None = None
    campus: str | None = None
    remark: str | None = None


class GradeItem(BaseModel):
    course_name: str = Field(alias="courseName")
    score: str | None = None
    credit: str | None = None
    grade_point: str | None = Field(default=None, alias="gradePoint")
    term: str | None = None


class AttendanceItem(BaseModel):
    course_name: str = Field(alias="courseName")
    course_code: str | None = Field(default=None, alias="courseCode")
    academic_year: str | None = Field(default=None, alias="academicYear")
    term: str | None = None
    normal: int = 0
    late: int = 0
    leave_early: int = Field(default=0, alias="leaveEarly")
    absent: int = 0
    leave: int = 0
    total: int = 0


class AttendanceResponse(BaseModel):
    status: Literal["not_implemented", "ok"] = "ok"
    items: list[AttendanceItem] = []


class CreditItem(BaseModel):
    student_id: str | None = Field(default=None, alias="studentId")
    name: str | None = None
    college: str | None = None
    major: str | None = None
    grade: str | None = None
    total_credit: str | None = Field(default=None, alias="totalCredit")
    required_credit: str | None = Field(default=None, alias="requiredCredit")
    selected_credit: str | None = Field(default=None, alias="selectedCredit")
    required_expected: float = Field(default=0, alias="requiredExpected")
    elective_expected: float = Field(default=0, alias="electiveExpected")
    other_expected: float = Field(default=0, alias="otherExpected")
    required_earned: float = Field(default=0, alias="requiredEarned")
    elective_earned: float = Field(default=0, alias="electiveEarned")
    other_earned: float = Field(default=0, alias="otherEarned")
    total_expected: float = Field(default=0, alias="totalExpected")
    total_earned: float = Field(default=0, alias="totalEarned")


class NoticeItem(BaseModel):
    category: str = "通知"
    title: str
    date: str | None = None
    url: str | None = None
    summary: str | None = None


class ErrorResponse(BaseModel):
    detail: str
