import { strict as assert } from "node:assert"
import { test } from "node:test"

import {
  parseAcademicPeriod,
  parseAttendance,
  parseEcardRooms,
  parseEcardConsumption,
  parseEcardConsumptionOverview,
  parseEcardSummary,
  parseEmpty,
  parseExams,
  parseGrades,
  parseLogin,
  parseNotices,
  parseScheduleCourses,
  parseScheduleSettings,
  parseStudentInfo
} from "../utils/parsers"

test("parseLogin 只保留四个安全字段", () => {
  const parsed = parseLogin({
    status: "ok",
    sessionId: "mini-session",
    studentName: "演示同学",
    studentId: "20260001",
    credentialToken: "must-not-leak",
    jwxtCookies: "must-not-leak",
    ehallCookies: "must-not-leak",
    ehallAuthToken: "must-not-leak"
  })

  assert.deepEqual(parsed, {
    status: "ok",
    sessionId: "mini-session",
    studentName: "演示同学",
    studentId: "20260001"
  })
  assert.deepEqual(Object.keys(parsed).sort(), ["sessionId", "status", "studentId", "studentName"])
})

test("parseLogin 序列化后不包含任何凭据字段", () => {
  const parsed = parseLogin({
    status: "ok",
    sessionId: "mini-session",
    studentName: "演示同学",
    studentId: "20260001",
    credentialToken: "must-not-leak",
    jwxtCookies: "must-not-leak"
  })
  const serialized = JSON.stringify(parsed)

  assert.equal(serialized.includes("must-not-leak"), false)
  assert.equal(serialized.includes("Cookie"), false)
  assert.equal(serialized.includes("Token"), false)
})

test("parseLogin 拒绝非 ok 状态与缺失会话", () => {
  assert.throws(() => parseLogin({ status: "failed" }), /登录响应状态无效/)
  assert.throws(
    () => parseLogin({ status: "ok", studentName: "演示同学", studentId: "20260001" }),
    /登录会话字段无效/
  )
  assert.throws(() => parseLogin(null), /登录响应格式无效/)
  assert.throws(() => parseLogin([]), /登录响应格式无效/)
})

test("parseAcademicPeriod 支持历史空值并校验范围", () => {
  assert.equal(parseAcademicPeriod({ year: null, term: null }), null)
  assert.deepEqual(parseAcademicPeriod({ year: 2026, term: 1 }), { year: 2026, term: 1 })
  assert.throws(() => parseAcademicPeriod({ year: 1999, term: 1 }), /学年字段无效/)
  assert.throws(() => parseAcademicPeriod({ year: 2026, term: 3 }), /学期字段无效/)
  assert.throws(() => parseAcademicPeriod({ year: 2026, term: null }), /学期字段无效/)
})

test("parseScheduleSettings 与微信绑定响应只接受明确结构", () => {
  assert.deepEqual(
    parseScheduleSettings({ firstWeeks: { "2026-1": "2026-09-01" } }),
    { firstWeeks: { "2026-1": "2026-09-01" } }
  )
  assert.throws(() => parseScheduleSettings({ firstWeeks: [] }), /课表设置响应格式无效/)
})

test("parseStudentInfo 接受可空字段并拒绝缺失姓名", () => {
  const parsed = parseStudentInfo({
    studentId: "20260001",
    name: "演示同学",
    college: null,
    major: "软件工程",
    className: undefined,
    grade: 2026,
    phone: null,
    email: "demo@example.com"
  })

  assert.deepEqual(parsed, {
    studentId: "20260001",
    name: "演示同学",
    college: null,
    major: "软件工程",
    className: null,
    grade: null,
    phone: null,
    email: "demo@example.com"
  })
  assert.throws(() => parseStudentInfo({ studentId: "20260001" }), /姓名字段无效/)
})

test("parseScheduleCourses 校验数组并归一化可空数字", () => {
  const parsed = parseScheduleCourses([
    {
      name: "高等数学",
      teacher: "张老师",
      classroom: "A101",
      weekday: 1,
      startSection: 1,
      endSection: 2,
      weeks: "1-16"
    },
    { name: "大学英语", weekday: "1" }
  ])

  assert.equal(parsed.length, 2)
  assert.equal(parsed[0].weekday, 1)
  assert.equal(parsed[1].weekday, null)
  assert.equal(parsed[1].startSection, null)
  assert.throws(() => parseScheduleCourses({}), /课表响应格式无效/)
  assert.throws(() => parseScheduleCourses([{ teacher: "张老师" }]), /课程名称字段无效/)
})

test("parseGrades 归一化通过标记", () => {
  const parsed = parseGrades([
    { courseName: "高等数学", score: "92", credit: "4", gradePoint: "4.0", term: "2025-2026-1", gradePassed: true },
    { courseName: "体育", gradePassed: "yes" }
  ])

  assert.equal(parsed[0].gradePassed, true)
  assert.equal(parsed[1].gradePassed, null)
  assert.equal(parsed[1].score, null)
})

test("parseExams 要求课程名与日期", () => {
  const parsed = parseExams([{ courseName: "高等数学", date: "2026-01-12", time: "09:00" }])
  assert.equal(parsed[0].date, "2026-01-12")
  assert.throws(() => parseExams([{ courseName: "高等数学" }]), /考试日期字段无效/)
})

test("parseAttendance 解析学期汇总与点名记录", () => {
  const parsed = parseAttendance({
    status: "ok",
    items: [{
      courseId: "course-1",
      courseName: "高等数学",
      courseCode: "MATH-101",
      normal: 10,
      late: 1,
      leaveEarly: 0,
      absent: 1,
      leave: 2,
      total: 14,
      records: [{ date: "2026-03-01", status: "late", count: 1 }]
    }]
  })

  assert.equal(parsed.items[0].courseName, "高等数学")
  assert.equal(parsed.items[0].late, 1)
  assert.equal(parsed.items[0].records[0].statusLabel, "迟到")
  assert.throws(() => parseAttendance({ status: "ok", items: [{ courseName: "高数", late: -1 }] }), /迟到次数字段无效/)
  assert.throws(() => parseAttendance({ status: "failed", items: [] }), /考勤响应状态无效/)
})

test("parseNotices 只接受四种已知来源", () => {
  const parsed = parseNotices([{ category: "教务", title: "选课通知", source: "jwxt" }])
  assert.equal(parsed[0].source, "jwxt")
  assert.throws(
    () => parseNotices([{ category: "教务", title: "选课通知", source: "unknown" }]),
    /通知来源字段无效/
  )
})

test("parseEcardSummary 区分未绑定与正常状态", () => {
  const notBound = parseEcardSummary({ status: "not_bound" })
  assert.equal(notBound.status, "not_bound")
  assert.equal(notBound.stale, false)

  const ok = parseEcardSummary({ status: "ok", powerText: "68.4 度", stale: true })
  assert.equal(ok.powerText, "68.4 度")
  assert.equal(ok.stale, true)

  assert.throws(() => parseEcardSummary({ status: "error" }), /生活缴费状态无效/)
  assert.throws(() => parseEcardSummary("not_bound"), /生活缴费响应格式无效/)
})

test("parseEcardConsumption 解析月份明细并保留空字段", () => {
  const parsed = parseEcardConsumption({
    status: "ok",
    cachedAt: "2026-09-19T08:00:00+08:00",
    items: [{ title: "宿舍电费", date: "2026-09-18", usage: 4.2 }]
  })

  assert.equal(parsed.status, "ok")
  assert.equal(parsed.items[0].usage, 4.2)
  assert.equal(parsed.items[0].unit, "度")
  assert.equal(parsed.items[0].amount, "")
  assert.throws(() => parseEcardConsumption({ status: "ok", items: {} }), /电费消费记录响应格式无效/)
})

test("parseEcardConsumptionOverview 支持无水费历史的总览", () => {
  const parsed = parseEcardConsumptionOverview({
    status: "limited",
    message: "请先绑定宿舍。",
    months: [],
  })

  assert.equal(parsed.message, "请先绑定宿舍。")
  assert.deepEqual(parsed.coldWaterMonths, [])
  assert.deepEqual(parsed.hotWaterMonths, [])
  assert.throws(
    () => parseEcardConsumptionOverview({ status: "invalid", months: [] }),
    /水电费历史总览状态无效/
  )
})

test("parseEcardRooms 解析宿舍列表并保留绑定所需字段", () => {
  const parsed = parseEcardRooms([
    {
      id: "1|A1|A1|101",
      schoolArea: "演示校区",
      building: "A1",
      room: "101",
      displayName: "演示宿舍 A1-101"
    }
  ])

  assert.equal(parsed.length, 1)
  assert.equal(parsed[0].id, "1|A1|A1|101")
  assert.equal(parsed[0].displayName, "演示宿舍 A1-101")
})

test("parseEcardRooms 要求 id 与 displayName", () => {
  assert.throws(
    () => parseEcardRooms([{ displayName: "A1-101" }]),
    /宿舍标识字段无效/
  )
  assert.throws(
    () => parseEcardRooms([{ id: "1|A1|A1|101" }]),
    /宿舍名称字段无效/
  )
  assert.throws(() => parseEcardRooms({}), /宿舍列表响应格式无效/)
})

test("parseEcardRooms 展示字段缺失时降级为空串而不报错", () => {
  const parsed = parseEcardRooms([{ id: "1|A1|A1|101", displayName: "A1-101" }])

  assert.equal(parsed[0].schoolArea, "")
  assert.equal(parsed[0].building, "")
  assert.equal(parsed[0].room, "")
})

test("parseEcardRooms 空列表是合法响应", () => {
  assert.deepEqual(parseEcardRooms([]), [])
})

test("parseEmpty 要求对象响应", () => {
  assert.deepEqual(parseEmpty({ status: "ok" }), {})
  assert.throws(() => parseEmpty([]), /退出登录响应格式无效/)
})
