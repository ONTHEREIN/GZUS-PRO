from typing import Any, Literal
from datetime import date

from pydantic import AliasChoices, BaseModel, ConfigDict, Field


class LoginRequest(BaseModel):
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


class CaptchaRequest(BaseModel):
    captcha_token: str = Field(alias="captchaToken", min_length=1)
    code: str = Field(min_length=1)


class SsoCompleteRequest(BaseModel):
    sso_code: str = Field(alias="ssoCode", min_length=1)


class PushRegisterRequest(BaseModel):
    registration_id: str = Field(alias="registrationId", min_length=1)
    platform: str = "android"


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


class EcardConsumptionItem(BaseModel):
    title: str
    amount: str = ""
    time: str = ""


class EcardConsumptionResponse(BaseModel):
    status: Literal["ok", "limited"]
    message: str | None = None
    items: list[EcardConsumptionItem] = []


class AuthResponse(BaseModel):
    status: Literal["ok", "captcha_required"]
    session_id: str | None = Field(default=None, alias="sessionId")
    student_name: str | None = Field(default=None, alias="studentName")
    student_id: str | None = Field(default=None, alias="studentId")
    captcha_token: str | None = Field(default=None, alias="captchaToken")
    captcha_image: str | None = Field(default=None, alias="captchaImage")
    credential_token: str | None = Field(default=None, alias="credentialToken")
    jwxt_cookies: str | None = Field(default=None, alias="jwxtCookies")
    ehall_cookies: str | None = Field(default=None, alias="ehallCookies")
    ehall_auth_token: str | None = Field(default=None, alias="ehallAuthToken")


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


class LeaveFillRequest(LeavePreviewRequest):
    reason: str = Field(min_length=1)
    attachment_name: str = Field(alias="attachmentName", min_length=1)
    attachment_content_base64: str = Field(alias="attachmentContentBase64", min_length=1)
    teacher_handlers: list[TeacherHandlerSelection] = Field(default=[], alias="teacherHandlers")


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


class ErrorResponse(BaseModel):
    detail: str


class EhallLoginRequest(BaseModel):
    account: str = Field(
        min_length=1,
        validation_alias=AliasChoices("account", "studentId", "student_id", "username"),
    )
    password: str = Field(min_length=1)


class AutoLoginRequest(BaseModel):
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


class EhallLoginResponse(BaseModel):
    status: Literal["ok", "error"]
    message: str | None = None
    session_id: int | None = Field(default=None, alias="sessionId")


class EhallSessionStatus(BaseModel):
    status: Literal["valid", "expired", "not_found"]
    account: str | None = None
    expires_at: str | None = Field(default=None, alias="expiresAt")
    last_used_at: str | None = Field(default=None, alias="lastUsedAt")


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
