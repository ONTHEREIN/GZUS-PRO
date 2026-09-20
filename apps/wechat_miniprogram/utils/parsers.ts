import {
  EcardRoom,
  EcardConsumptionResponse,
  EcardSummary,
  EcardConsumptionItem,
  EcardConsumptionMonthOverview,
  EcardConsumptionOverviewResponse,
  EcardWaterMonthOverview,
  AcademicPeriod,
  AttendanceItem,
  AttendanceRecord,
  AttendanceResponse,
  ScheduleSettings,
  ExamItem,
  GradeItem,
  LoginResponse,
  NoticeItem,
  ScheduleCourse,
  StudentInfo
} from "./models"

type JsonRecord = Record<string, unknown>

function record(value: unknown, label: string): JsonRecord {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label}响应格式无效`)
  }
  return value as JsonRecord
}

function stringValue(value: unknown, label: string): string {
  if (typeof value !== "string") throw new Error(`${label}字段无效`)
  return value
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" ? value : null
}

function nullableNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function nullableBoolean(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null
}

function nonNegativeInteger(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error(`${label}字段无效`)
  }
  return value
}

function list(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${label}响应格式无效`)
  return value
}

function optionalList(value: unknown, label: string): unknown[] {
  return value === undefined ? [] : list(value, label)
}

export function parseLogin(value: unknown): LoginResponse {
  const item = record(value, "登录")
  if (item.status !== "ok") throw new Error("登录响应状态无效")
  return {
    status: "ok",
    sessionId: stringValue(item.sessionId, "登录会话"),
    studentName: stringValue(item.studentName, "学生姓名"),
    studentId: stringValue(item.studentId, "学号")
  }
}

export function parseAcademicPeriod(value: unknown): AcademicPeriod | null {
  const item = record(value, "学年学期")
  if (item.year === null && item.term === null) return null
  if (typeof item.year !== "number" || !Number.isInteger(item.year) || item.year < 2000 || item.year > 3000) {
    throw new Error("学年字段无效")
  }
  if (item.term !== 1 && item.term !== 2) throw new Error("学期字段无效")
  return { year: item.year, term: item.term }
}

export function parseScheduleSettings(value: unknown): ScheduleSettings {
  const item = record(value, "课表设置")
  if (typeof item.firstWeeks !== "object" || item.firstWeeks === null || Array.isArray(item.firstWeeks)) {
    throw new Error("课表设置响应格式无效")
  }
  const firstWeeks: Record<string, string> = {}
  for (const [key, value] of Object.entries(item.firstWeeks)) {
    if (typeof value !== "string") throw new Error("第一周日期格式无效")
    firstWeeks[key] = value
  }
  return { firstWeeks }
}

export function parseWechatBindingStatus(value: unknown): { isBound: boolean } {
  const item = record(value, "微信绑定")
  if (typeof item.isBound !== "boolean") throw new Error("微信绑定状态无效")
  return { isBound: item.isBound }
}

export function parseWechatBindingResponse(value: unknown): Record<string, never> {
  const item = record(value, "微信绑定")
  if (item.status !== "ok") throw new Error("微信绑定响应状态无效")
  return {}
}

export function parseStudentInfo(value: unknown): StudentInfo {
  const item = record(value, "个人信息")
  return {
    studentId: stringValue(item.studentId, "学号"),
    name: stringValue(item.name, "姓名"),
    college: nullableString(item.college),
    major: nullableString(item.major),
    className: nullableString(item.className),
    grade: nullableString(item.grade),
    phone: nullableString(item.phone),
    email: nullableString(item.email)
  }
}

export function parseScheduleCourses(value: unknown): ScheduleCourse[] {
  return list(value, "课表").map((entry) => {
    const item = record(entry, "课表")
    return {
      name: stringValue(item.name, "课程名称"),
      teacher: nullableString(item.teacher),
      classroom: nullableString(item.classroom),
      weekday: nullableNumber(item.weekday),
      startSection: nullableNumber(item.startSection),
      endSection: nullableNumber(item.endSection),
      weeks: nullableString(item.weeks)
    }
  })
}

export function parseGrades(value: unknown): GradeItem[] {
  return list(value, "成绩").map((entry) => {
    const item = record(entry, "成绩")
    return {
      courseName: stringValue(item.courseName, "课程名称"),
      score: nullableString(item.score),
      credit: nullableString(item.credit),
      gradePoint: nullableString(item.gradePoint),
      term: nullableString(item.term),
      gradePassed: nullableBoolean(item.gradePassed)
    }
  })
}

export function parseExams(value: unknown): ExamItem[] {
  return list(value, "考试").map((entry) => {
    const item = record(entry, "考试")
    return {
      courseName: stringValue(item.courseName, "课程名称"),
      date: stringValue(item.date, "考试日期"),
      time: nullableString(item.time),
      location: nullableString(item.location),
      seat: nullableString(item.seat)
    }
  })
}

function attendanceStatusLabel(status: string): string | null {
  const labels: Record<string, string> = {
    normal: "正常",
    late: "迟到",
    leaveEarly: "早退",
    absent: "旷课",
    leave: "请假"
  }
  return labels[status] || null
}

function parseAttendanceRecord(value: unknown): AttendanceRecord {
  const item = record(value, "考勤记录")
  const status = typeof item.status === "string" && item.status ? item.status : "normal"
  return {
    date: nullableString(item.date),
    status,
    statusLabel: nullableString(item.statusLabel) || attendanceStatusLabel(status),
    count: item.count === undefined ? 1 : nonNegativeInteger(item.count, "考勤次数"),
    time: nullableString(item.time),
    remark: nullableString(item.remark)
  }
}

function parseAttendanceItem(value: unknown): AttendanceItem {
  const item = record(value, "考勤课程")
  const records = item.records === undefined ? [] : list(item.records, "考勤记录")
  return {
    courseId: typeof item.courseId === "string" ? item.courseId : "",
    courseName: stringValue(item.courseName, "课程名称"),
    courseCode: nullableString(item.courseCode),
    academicYear: nullableString(item.academicYear),
    term: nullableString(item.term),
    normal: item.normal === undefined ? 0 : nonNegativeInteger(item.normal, "正常次数"),
    late: item.late === undefined ? 0 : nonNegativeInteger(item.late, "迟到次数"),
    leaveEarly: item.leaveEarly === undefined ? 0 : nonNegativeInteger(item.leaveEarly, "早退次数"),
    absent: item.absent === undefined ? 0 : nonNegativeInteger(item.absent, "旷课次数"),
    leave: item.leave === undefined ? 0 : nonNegativeInteger(item.leave, "请假次数"),
    total: item.total === undefined ? 0 : nonNegativeInteger(item.total, "考勤总次数"),
    records: records.map(parseAttendanceRecord)
  }
}

export function parseAttendance(value: unknown): AttendanceResponse {
  const item = record(value, "考勤")
  if (item.status !== "ok" && item.status !== "not_implemented") {
    throw new Error("考勤响应状态无效")
  }
  return {
    status: item.status,
    items: list(item.items, "考勤").map(parseAttendanceItem)
  }
}

export function parseNotices(value: unknown): NoticeItem[] {
  return list(value, "通知").map((entry) => {
    const item = record(entry, "通知")
    const source = item.source
    if (source !== "jwxt" && source !== "ehall" && source !== "admin" && source !== "wechat") {
      throw new Error("通知来源字段无效")
    }
    return {
      category: stringValue(item.category, "通知分类"),
      title: stringValue(item.title, "通知标题"),
      date: nullableString(item.date),
      summary: nullableString(item.summary),
      source
    }
  })
}

export function parseEcardSummary(value: unknown): EcardSummary {
  const item = record(value, "生活缴费")
  if (item.status !== "ok" && item.status !== "not_bound") {
    throw new Error("生活缴费状态无效")
  }
  return {
    status: item.status,
    roomDisplay: nullableString(item.roomDisplay),
    powerText: nullableString(item.powerText),
    coldWaterText: nullableString(item.coldWaterText),
    hotWaterText: nullableString(item.hotWaterText),
    stale: item.stale === true
  }
}

function parseEcardConsumptionItem(value: unknown): EcardConsumptionItem {
  const item = record(value, "电费消费记录")
  return {
    title: nullableString(item.title) || "电费消费",
    amount: nullableString(item.amount) || "",
    time: nullableString(item.time) || "",
    date: nullableString(item.date) || "",
    usage: nullableNumber(item.usage),
    unit: nullableString(item.unit) || "度"
  }
}

export function parseEcardConsumption(value: unknown): EcardConsumptionResponse {
  const item = record(value, "电费历史")
  if (item.status !== "ok" && item.status !== "limited") {
    throw new Error("电费历史状态无效")
  }
  return {
    status: item.status,
    message: nullableString(item.message),
    cachedAt: nullableString(item.cachedAt),
    items: list(item.items, "电费消费记录").map(parseEcardConsumptionItem)
  }
}

function parseEcardConsumptionMonthOverview(value: unknown): EcardConsumptionMonthOverview {
  const item = record(value, "电费月度概览")
  return {
    month: stringValue(item.month, "概览月份"),
    recordedDays: nullableNumber(item.recordedDays) || 0,
    totalUsage: nullableNumber(item.totalUsage) || 0,
    averageDailyUsage: nullableNumber(item.averageDailyUsage) || 0,
    peakDate: nullableString(item.peakDate) || "",
    peakUsage: nullableNumber(item.peakUsage) || 0,
    unit: nullableString(item.unit) || "度",
    cachedAt: nullableString(item.cachedAt) || ""
  }
}

function parseEcardWaterMonthOverview(value: unknown): EcardWaterMonthOverview {
  const item = record(value, "水费月度概览")
  return {
    month: stringValue(item.month, "概览月份"),
    recordedDays: nullableNumber(item.recordedDays) || 0,
    openingBalance: nullableNumber(item.openingBalance) || 0,
    closingBalance: nullableNumber(item.closingBalance) || 0,
    estimatedUsage: nullableNumber(item.estimatedUsage) || 0,
    estimatedRecharge: nullableNumber(item.estimatedRecharge) || 0,
    averageDailyUsage: nullableNumber(item.averageDailyUsage) || 0,
    peakDate: nullableString(item.peakDate),
    peakUsage: nullableNumber(item.peakUsage) || 0,
    unit: stringValue(item.unit, "水费单位"),
    cachedAt: nullableString(item.cachedAt) || ""
  }
}

export function parseEcardConsumptionOverview(value: unknown): EcardConsumptionOverviewResponse {
  const item = record(value, "水电费历史总览")
  if (item.status !== "ok" && item.status !== "limited") {
    throw new Error("水电费历史总览状态无效")
  }
  return {
    status: item.status,
    message: nullableString(item.message),
    months: list(item.months, "电费月度概览").map(parseEcardConsumptionMonthOverview),
    coldWaterMonths: optionalList(item.coldWaterMonths, "冷水月度概览").map(parseEcardWaterMonthOverview),
    hotWaterMonths: optionalList(item.hotWaterMonths, "热水月度概览").map(parseEcardWaterMonthOverview)
  }
}

/**
 * 宿舍列表（绑定用）。
 *
 * `id` 与 `displayName` 是绑定的必填项：后端会用 `EcardRoomRef.from_id` 校验 id
 * 必须是 4 段竖线分隔，并把 displayName 落库展示，所以这两个字段缺一不可。
 * 校区/楼栋/房间号只用于界面展示，缺失时降级为空串而不是报错。
 */
export function parseEcardRooms(value: unknown): EcardRoom[] {
  return list(value, "宿舍列表").map((entry) => {
    const item = record(entry, "宿舍")
    return {
      id: stringValue(item.id, "宿舍标识"),
      schoolArea: nullableString(item.schoolArea) || "",
      building: nullableString(item.building) || "",
      room: nullableString(item.room) || "",
      displayName: stringValue(item.displayName, "宿舍名称")
    }
  })
}

export function parseEmpty(value: unknown): Record<string, never> {
  record(value, "退出登录")
  return {}
}
