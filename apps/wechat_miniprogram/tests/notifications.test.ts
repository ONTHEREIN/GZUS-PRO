import { strict as assert } from "node:assert"
import { test } from "node:test"
import { gradeResult } from "../utils/grades"
import { parseGrades } from "../utils/parsers"
import { parseNotificationConfig, parseReminders, reminderDestination } from "../utils/notifications"

test("成绩展示保留服务端结论、待公布与未知状态", () => {
  const grades = parseGrades([
    { courseName: "59", score: "59", gradePassed: false }, { courseName: "60", score: "60", gradePassed: true },
    { courseName: "官方不及格", score: "90", gradePassed: false }, { courseName: "文字成绩", score: "合格", gradePassed: true },
    { courseName: "未知", score: "优秀", gradePassed: null }, { courseName: "待公布", score: "", gradePassed: null }, { courseName: "文字待公布", score: "待公布", gradePassed: null }
  ])
  assert.deepEqual(grades.map(gradeResult).map((item) => item.resultText), ["不及格", "及格", "不及格", "及格", "无法判断", "待公布", "待公布"])
})

test("五类提醒解析、未读与跳转，忽略其他事件但拒绝损坏数据", () => {
  const events = ["exam_reminder", "grade_update", "course_reminder", "attendance_update", "ecard_reminder"].map((type) => ({
    id: type, type, title: "提醒", body: "内容", createdAt: "2026-10-04", readAt: null
  }))
  const reminders = parseReminders({ events: [...events, { type: "new_notice" }] })
  assert.equal(reminders.length, 5)
  assert.equal(reminderDestination(reminders[2].type).tab, true)
  assert.equal(reminderDestination(reminders[4].type).url, "/pages/ecard/index")
  assert.throws(() => parseReminders({ events: [{ ...events[0], readAt: 3 }] }))
})

test("模板待配置、拒绝、封禁和可用次数均有明确状态", () => {
  const config = parseNotificationConfig({ bound: true, backgroundAuthorized: true, lastCheckedAt: null, lastError: null,
    settings: [
      { type: "grade_update", label: "成绩", templateId: null, enabled: true, credits: 0, subscriptionStatus: "not_subscribed", lastError: null },
      { type: "course_reminder", label: "课程", templateId: "id", enabled: true, credits: 2, subscriptionStatus: "accept", lastError: null },
      { type: "attendance_update", label: "考勤", templateId: "id", enabled: true, credits: 0, subscriptionStatus: "ban", lastError: null }
    ] })
  assert.deepEqual(config.settings.map((row) => row.statusText), ["模板待配置", "可提醒 2 次", "订阅已被封禁"])
  assert.throws(() => parseNotificationConfig({ ...config, settings: [{ ...config.settings[0], credits: -1 }] }))
})
