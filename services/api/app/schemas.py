from typing import Any, Literal
from datetime import date, datetime

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, model_validator


LEAVE_ATTACHMENT_MAX_COUNT = 5
LEAVE_ATTACHMENT_MAX_BYTES = 7 * 1024 * 1024


class CredentialLoginRequest(BaseModel):
    account: str = Field(
        min_length=1,
        validation_alias=AliasChoices("account", "studentId", "student_id", "username"),
    )
    password: str | None = Field(default=None, min_length=1)
    encrypted_password: str | None = Field(default=None, alias="encryptedPassword")
    key_id: str | None = Field(default=None, alias="keyId")

    def resolve_password(self) -> str:
        """Return the plaintext password, decrypting encrypted_password if needed."""
        if self.encrypted_password is not None:
            from app.rsa_keys import rsa_key_manager

            try:
                return rsa_key_manager.decrypt(self.encrypted_password)
            except Exception:
                raise ValueError("密码解密失败，请重新登录")
        if self.password is not None:
            return self.password
        raise ValueError("必须提供 password 或 encryptedPassword")


class SsoCompleteRequest(BaseModel):
    sso_code: str = Field(alias="ssoCode", min_length=1)


class NativeSsoStartRequest(BaseModel):
    verifier: str = Field(min_length=32, max_length=256)


class NativeSsoStartResponse(BaseModel):
    authorization_url: str = Field(alias="authorizationUrl")


class NativeSsoCompleteRequest(BaseModel):
    code: str = Field(min_length=32, max_length=256)
    verifier: str = Field(min_length=32, max_length=256)


class EcardBindingRequest(BaseModel):
    room_id: str = Field(alias="roomId", min_length=1)
    room_display: str = Field(alias="roomDisplay", min_length=1)


class EcardReminderRequest(BaseModel):
    enabled: bool | None = None
    low_power_threshold: float | None = Field(default=None, alias="lowPowerThreshold", ge=0)
    low_cold_water_threshold: float | None = Field(
        default=None, alias="lowColdWaterThreshold", ge=0
    )
    low_hot_water_threshold: float | None = Field(default=None, alias="lowHotWaterThreshold", ge=0)
    reminder_times: list[str] | None = Field(default=None, alias="reminderTimes", max_length=2)
    reminder_items: list[str] | None = Field(default=None, alias="reminderItems")


class EcardSummaryCacheRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    power_balance: float | str | None = Field(default=None, alias="powerBalance")
    power_unit: str | None = Field(default=None, alias="powerUnit")
    power_text: str | None = Field(default=None, alias="powerText")
    cold_water_balance: float | str | None = Field(default=None, alias="coldWaterBalance")
    cold_water_unit: str | None = Field(default=None, alias="coldWaterUnit")
    cold_water_text: str | None = Field(default=None, alias="coldWaterText")
    hot_water_balance: float | str | None = Field(default=None, alias="hotWaterBalance")
    hot_water_unit: str | None = Field(default=None, alias="hotWaterUnit")
    hot_water_text: str | None = Field(default=None, alias="hotWaterText")
    updated_at: str | None = Field(default=None, alias="updatedAt")


class EcardRoomItem(BaseModel):
    id: str
    school_area: str = Field(alias="schoolArea")
    building: str
    room: str
    display_name: str = Field(alias="displayName")


class EcardSummary(BaseModel):
    status: Literal["ok", "not_bound"]
    student_id: str | None = Field(default=None, alias="studentId")
    room_id: str | None = Field(default=None, alias="roomId")
    room_display: str | None = Field(default=None, alias="roomDisplay")
    power_balance: float | str | None = Field(default=None, alias="powerBalance")
    power_unit: str = Field(default="度", alias="powerUnit")
    power_text: str | None = Field(default=None, alias="powerText")
    cold_water_balance: float | str | None = Field(default=None, alias="coldWaterBalance")
    cold_water_unit: str = Field(default="吨", alias="coldWaterUnit")
    cold_water_text: str | None = Field(default=None, alias="coldWaterText")
    hot_water_balance: float | str | None = Field(default=None, alias="hotWaterBalance")
    hot_water_unit: str = Field(default="元", alias="hotWaterUnit")
    hot_water_text: str | None = Field(default=None, alias="hotWaterText")
    reminder_enabled: bool = Field(default=True, alias="reminderEnabled")
    low_power_threshold: float = Field(default=30, alias="lowPowerThreshold")
    low_cold_water_threshold: float = Field(default=5.0, alias="lowColdWaterThreshold")
    low_hot_water_threshold: float = Field(default=10.0, alias="lowHotWaterThreshold")
    reminder_times: list[str] = Field(default=["08:00"], alias="reminderTimes")
    reminder_items: list[str] = Field(
        default=["power", "cold_water", "hot_water"], alias="reminderItems"
    )
    updated_at: str | None = Field(default=None, alias="updatedAt")
    # 刷新失败时后端以旧缓存兜底返回，stale=true 供前端提示"当前为缓存数据"
    stale: bool = False
    stale_reason: str | None = Field(default=None, alias="staleReason")


class EcardConsumptionItem(BaseModel):
    title: str
    amount: str = ""
    time: str = ""
    date: str = ""
    usage: float | None = None
    unit: str = "度"


class EcardConsumptionResponse(BaseModel):
    status: Literal["ok", "limited"]
    message: str | None = None
    items: list[EcardConsumptionItem] = []
    cached_at: str | None = Field(default=None, alias="cachedAt")


class EcardConsumptionMonthOverview(BaseModel):
    month: str
    recorded_days: int = Field(alias="recordedDays")
    total_usage: float = Field(alias="totalUsage")
    average_daily_usage: float = Field(alias="averageDailyUsage")
    peak_date: str = Field(alias="peakDate")
    peak_usage: float = Field(alias="peakUsage")
    unit: str = "度"
    cached_at: str = Field(alias="cachedAt")


class EcardConsumptionOverviewResponse(BaseModel):
    status: Literal["ok", "limited"]
    message: str | None = None
    months: list[EcardConsumptionMonthOverview] = []


class AuthResponse(BaseModel):
    status: Literal["ok"]
    session_id: str | None = Field(default=None, alias="sessionId")
    student_name: str | None = Field(default=None, alias="studentName")
    student_id: str = Field(alias="studentId")
    credential_token: str | None = Field(default=None, alias="credentialToken")
    jwxt_cookies: str | None = Field(default=None, alias="jwxtCookies")
    ehall_cookies: str | None = Field(default=None, alias="ehallCookies")
    ehall_auth_token: str | None = Field(default=None, alias="ehallAuthToken")
    # 管理后台标记：学号在 admin_users 白名单中时为 True（由登录链路填充）
    is_admin: bool | None = Field(default=None, alias="isAdmin")


class ReloginRequest(BaseModel):
    credential_token: str = Field(alias="credentialToken", min_length=1)


class StudentInfo(BaseModel):
    student_id: str = Field(alias="studentId")
    name: str = ""
    college: str | None = None
    major: str | None = None
    class_name: str | None = Field(default=None, alias="className")
    grade: str | None = None
    gender: str | None = None
    id_number: str | None = Field(default=None, alias="idNumber")
    birth_date: str | None = Field(default=None, alias="birthDate")
    ethnicity: str | None = None
    political_status: str | None = Field(default=None, alias="politicalStatus")
    enroll_date: str | None = Field(default=None, alias="enrollDate")
    native_place: str | None = Field(default=None, alias="nativePlace")
    student_status: str | None = Field(default=None, alias="studentStatus")
    education_level: str | None = Field(default=None, alias="educationLevel")
    phone: str | None = None
    email: str | None = None
    address: str | None = None
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
    date: str = ""
    weekday: str = ""
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


class AttendanceRecord(BaseModel):
    date: str | None = None
    status: str = "normal"
    status_label: str | None = Field(default=None, alias="statusLabel")
    count: int = 1
    time: str | None = None
    remark: str | None = None


class AttendanceItem(BaseModel):
    course_id: str = Field(default="", alias="courseId")
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
    records: list[AttendanceRecord] = []


class AttendanceResponse(BaseModel):
    status: Literal["not_implemented", "ok"] = "ok"
    items: list[AttendanceItem] = []


class AttendanceDetail(BaseModel):
    academic_year: str = Field(default="", alias="academicYear")
    term: str = ""
    status: str = "normal"
    status_label: str = Field(default="正常", alias="statusLabel")
    offering_college: str = Field(default="", alias="offeringCollege")
    course_code: str = Field(default="", alias="courseCode")
    course_name: str = Field(default="", alias="courseName")
    teaching_class: str = Field(default="", alias="teachingClass")
    teacher: str = ""
    roll_call_time: str = Field(default="", alias="rollCallTime")
    class_date: str = Field(default="", alias="classDate")
    class_time: str = Field(default="", alias="classTime")
    sections: str = ""
    student_id: str = Field(default="", alias="studentId")
    student_name: str = Field(default="", alias="studentName")
    gender: str = ""
    college: str = ""
    grade: str = ""
    major: str = ""
    class_name: str = Field(default="", alias="className")
    remark: str = ""


class AttendanceDetailResponse(BaseModel):
    items: list[AttendanceDetail] = []


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
    content_summary: str | None = None
    cover_url: str | None = Field(default=None, alias="coverUrl")
    source: Literal["jwxt", "ehall", "admin", "wechat"] = "jwxt"


class NoticeDetail(BaseModel):
    title: str = ""
    date: str | None = None
    content_html: str = Field(default="", alias="contentHtml")
    url: str


class EhallAffairItem(BaseModel):
    id: str | None = None
    title: str
    department: str | None = None
    type: str | None = None
    tags: list[str] = []
    summary: str | None = None
    url: str | None = None


class EhallApplicationItem(EhallAffairItem):
    pass


class EhallProgressItem(BaseModel):
    id: str | None = None
    title: str
    category: str
    status: str
    status_label: str = Field(alias="statusLabel")
    date: str | None = None
    summary: str | None = None
    current_node: str | None = Field(default=None, alias="currentNode")
    handler: str | None = None
    progress: int | None = None
    url: str | None = None


class EhallProgressCategory(BaseModel):
    label: str
    count: int = 0


class EhallProgressOverview(BaseModel):
    categories: list[EhallProgressCategory] = Field(default_factory=list)
    items: list[EhallProgressItem] = Field(default_factory=list)


class LeavePreviewRequest(BaseModel):
    year: int
    term: int
    start_date: date = Field(alias="startDate")
    end_date: date = Field(alias="endDate")
    first_week_start: date | None = Field(default=None, alias="firstWeekStart")
    courses: list[dict[str, Any]] = Field(default_factory=list)


class TeacherHandlerSelection(BaseModel):
    teacher: str
    userid: str
    cn_name: str = Field(alias="cnName")
    course_name: str | None = Field(default=None, alias="courseName")


class LeaveAttachmentItem(BaseModel):
    attachment_name: str = Field(alias="attachmentName", min_length=1)
    attachment_content_base64: str = Field(alias="attachmentContentBase64", min_length=1)


class LeaveFillRequest(LeavePreviewRequest):
    reason: str = Field(min_length=1)
    attachments: list[LeaveAttachmentItem] = Field(default_factory=list, max_length=LEAVE_ATTACHMENT_MAX_COUNT)
    attachment_name: str | None = Field(default=None, alias="attachmentName", min_length=1)
    attachment_content_base64: str | None = Field(
        default=None, alias="attachmentContentBase64", min_length=1
    )
    teacher_handlers: list[TeacherHandlerSelection] = Field(default=[], alias="teacherHandlers")

    @model_validator(mode="before")
    @classmethod
    def convert_legacy_attachment(cls, value: Any) -> Any:
        if not isinstance(value, dict):
            return value
        if value.get("attachments"):
            return value
        attachment_name = value.get("attachmentName")
        attachment_content = value.get("attachmentContentBase64")
        if attachment_name is None or attachment_content is None:
            return value
        return {
            **value,
            "attachments": [
                {
                    "attachmentName": attachment_name,
                    "attachmentContentBase64": attachment_content,
                }
            ],
        }

    @model_validator(mode="after")
    def require_attachments(self) -> "LeaveFillRequest":
        if not self.attachments:
            raise ValueError("请至少上传一张图片")
        return self


class LeaveAttachmentUploadRequest(BaseModel):
    doc_unid: str = Field(alias="docUnid", min_length=1)
    process_id: str = Field(default="", alias="processId")
    node_name: str = Field(default="申请人", alias="nodeName")
    local_store: str = Field(default="0", alias="localStore")
    attachment_name: str = Field(alias="attachmentName", min_length=1)
    attachment_content_base64: str = Field(alias="attachmentContentBase64", min_length=1)


class LeaveCourseItem(BaseModel):
    course_name: str = Field(alias="courseName")
    course_code: str | None = Field(default=None, alias="courseCode")
    teaching_class_code: str | None = Field(default=None, alias="teachingClassCode")
    course_nature: str | None = Field(default=None, alias="courseNature")
    credit: str | None = None
    class_time: str = Field(alias="classTime")
    class_times: list[str] = Field(default=[], alias="classTimes")
    absence_count: int = Field(alias="absenceCount")
    teacher: str | None = None
    missing_fields: list[str] = Field(default=[], alias="missingFields")


class LeavePreviewResponse(BaseModel):
    status: Literal["ok"]
    items: list[LeaveCourseItem]
    has_missing_fields: bool = Field(alias="hasMissingFields")


class StaffCandidateItem(BaseModel):
    userid: str
    cn_name: str = Field(alias="cnName")
    folder_name: str | None = Field(default=None, alias="folderName")


class MatchedTeacherItem(BaseModel):
    teacher: str
    userid: str
    cn_name: str = Field(alias="cnName")
    course_name: str | None = Field(default=None, alias="courseName")


class TeacherCandidateGroup(BaseModel):
    teacher: str
    candidates: list[StaffCandidateItem] = []


class LeaveFillResponse(BaseModel):
    status: Literal["filled", "needs_manual", "no_ehall_session"]
    message: str
    items: list[LeaveCourseItem] = []
    unmatched_teachers: list[str] = Field(default=[], alias="unmatchedTeachers")
    matched_teachers: list[MatchedTeacherItem] = Field(default=[], alias="matchedTeachers")
    teacher_candidates: list[TeacherCandidateGroup] = Field(default=[], alias="teacherCandidates")
    form_url: str | None = Field(default=None, alias="formUrl")
    fill_script: str | None = Field(default=None, alias="fillScript")
    handler_script: str | None = Field(default=None, alias="handlerScript")
    attachment_uploaded: bool = Field(default=False, alias="attachmentUploaded")
    attachment_uploaded_count: int = Field(default=0, alias="attachmentUploadedCount")
    attachment_total: int = Field(default=0, alias="attachmentTotal")


class AutoLoginRequest(CredentialLoginRequest):
    """统一认证账号密码登录请求。"""


class WebPushKeys(BaseModel):
    p256dh: str
    auth: str


class WebPushSubscriptionRequest(BaseModel):
    endpoint: str
    keys: WebPushKeys
    expiration_time: int | None = Field(default=None, alias="expirationTime")


class WebPushConfigResponse(BaseModel):
    enabled: bool
    publicKey: str | None = None


class IosPushTokenRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    device_token: str = Field(alias="deviceToken", min_length=32, max_length=512, pattern=r"^[A-Fa-f0-9]+$")
    environment: Literal["sandbox", "production"]


class CourseReminderSyncCourse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=200)
    weekday: int = Field(ge=1, le=7)
    start_section: int = Field(alias="startSection", ge=1, le=16)
    end_section: int = Field(alias="endSection", ge=1, le=16)
    classroom: str = Field(default="", max_length=200)
    teacher: str = Field(default="", max_length=100)
    weeks: list[int] = Field(default_factory=list, max_length=30)


class CourseReminderSyncRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool
    before_start_minutes: int = Field(alias="beforeStartMinutes", ge=1, le=120)
    before_end_minutes: int = Field(alias="beforeEndMinutes", ge=1, le=120)
    first_week_start: str = Field(alias="firstWeekStart", pattern=r"^\d{4}-\d{2}-\d{2}$")
    courses: list[CourseReminderSyncCourse] = Field(default_factory=list, max_length=200)


class BackgroundNotificationAccessRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool
    credential_token: str | None = Field(default=None, alias="credentialToken", min_length=1)
    course_reminder: CourseReminderSyncRequest | None = Field(default=None, alias="courseReminder")


class BackgroundNotificationStatus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool
    course_reminders_enabled: bool = Field(alias="courseRemindersEnabled")
    last_checked_at: datetime | None = Field(default=None, alias="lastCheckedAt")
    last_error: str | None = Field(default=None, alias="lastError")
    course_sync_error: str | None = Field(default=None, alias="courseSyncError")
    notices_enabled: bool = Field(alias="noticesEnabled")
    grades_enabled: bool = Field(alias="gradesEnabled")
    exams_enabled: bool = Field(alias="examsEnabled")
    attendance_enabled: bool = Field(alias="attendanceEnabled")


class NotificationPreferencesUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    notices_enabled: bool | None = Field(default=None, alias="noticesEnabled")
    grades_enabled: bool | None = Field(default=None, alias="gradesEnabled")
    exams_enabled: bool | None = Field(default=None, alias="examsEnabled")
    attendance_enabled: bool | None = Field(default=None, alias="attendanceEnabled")


class ScheduleSettingsUpdate(BaseModel):
    """课表偏好设置更新（部分字段可选，未传字段保持不变）。

    firstWeeks 为合并语义：键 "{year}-{term}"（如 "2026-1"），值 yyyy-MM-dd。
    """

    model_config = ConfigDict(extra="forbid")

    first_weeks: dict[str, str] | None = Field(default=None, alias="firstWeeks")
    auto_week: bool | None = Field(default=None, alias="autoWeek")
    onboarding_completed: bool | None = Field(default=None, alias="onboardingCompleted")


class ScheduleSettings(BaseModel):
    """按用户绑定的课表偏好设置（开学日期等，云端同步）。"""

    model_config = ConfigDict(extra="forbid")

    first_weeks: dict[str, str] = Field(default_factory=dict, alias="firstWeeks")
    auto_week: bool = Field(default=True, alias="autoWeek")
    onboarding_completed: bool = Field(default=False, alias="onboardingCompleted")
