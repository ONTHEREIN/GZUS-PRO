export interface LoginResponse {
  status: "ok"
  sessionId: string
  studentName: string
  studentId: string
}

export interface AcademicPeriod {
  year: number
  term: 1 | 2
}

export interface ScheduleSettings {
  firstWeeks: Record<string, string>
}

export interface WechatBindingStatus {
  isBound: boolean
}

export interface StudentInfo {
  studentId: string
  name: string
  college: string | null
  major: string | null
  className: string | null
  grade: string | null
  phone: string | null
  email: string | null
}

export interface ScheduleCourse {
  name: string
  teacher: string | null
  classroom: string | null
  weekday: number | null
  startSection: number | null
  endSection: number | null
  weeks: string | null
}

export interface GradeItem {
  courseName: string
  score: string | null
  credit: string | null
  gradePoint: string | null
  term: string | null
  gradePassed: boolean | null
}

export interface ExamItem {
  courseName: string
  date: string
  time: string | null
  location: string | null
  seat: string | null
}

export interface NoticeItem {
  category: string
  title: string
  date: string | null
  summary: string | null
  source: "jwxt" | "ehall" | "admin" | "wechat"
}

export interface EcardSummary {
  status: "ok" | "not_bound"
  roomDisplay: string | null
  powerText: string | null
  coldWaterText: string | null
  hotWaterText: string | null
  stale: boolean
}

/** 可绑定的宿舍条目（来自 /ecard/rooms）。 */
export interface EcardRoom {
  /** 形如 `<implType>|<校区>|<楼栋>|<房间号>`，后端会校验必须为 4 段。 */
  id: string
  schoolArea: string
  building: string
  room: string
  displayName: string
}
