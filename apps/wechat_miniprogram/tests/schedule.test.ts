import { strict as assert } from "node:assert"
import { test } from "node:test"

import { ScheduleCourse } from "../utils/models"
import {
  buildWeekRows,
  courseTimeText,
  dateForWeek,
  mondayOf,
  occursInWeek,
  parseScheduleDate,
  weekFromDate
} from "../utils/schedule"

function course(overrides: Partial<ScheduleCourse>): ScheduleCourse {
  return {
    name: "测试课程",
    teacher: "测试老师",
    classroom: "A101",
    weekday: 1,
    startSection: 1,
    endSection: 2,
    weeks: "1-16",
    ...overrides
  }
}

test("周次日期换算归一到周一并限制在 1 至 30 周", () => {
  const firstWeek = parseScheduleDate("2026-08-31")!
  assert.equal(parseScheduleDate("2026-02-30"), null)
  const monday = mondayOf(parseScheduleDate("2026-09-06")!)
  const weekThreeWednesday = dateForWeek(firstWeek, 3, 2)
  assert.deepEqual([monday.getFullYear(), monday.getMonth() + 1, monday.getDate()], [2026, 8, 31])
  assert.deepEqual(
    [weekThreeWednesday.getFullYear(), weekThreeWednesday.getMonth() + 1, weekThreeWednesday.getDate()],
    [2026, 9, 16]
  )
  assert.equal(weekFromDate(firstWeek, parseScheduleDate("2026-09-14")!), 3)
  assert.equal(weekFromDate(firstWeek, parseScheduleDate("2026-07-01")!), 1)
  assert.equal(weekFromDate(firstWeek, parseScheduleDate("2027-08-01")!), 30)
})

test("课表周次解析支持单周、双周、区间和中文标点", () => {
  assert.equal(occursInWeek("1-8单周", 1), true)
  assert.equal(occursInWeek("1-8单周", 2), false)
  assert.equal(occursInWeek("1-8双周", 2), true)
  assert.equal(occursInWeek("1、3、5", 3), true)
  assert.equal(occursInWeek("1、3、5", 2), false)
  assert.equal(occursInWeek(null, 20), true)
})

test("课程节次转换为首页展示时间", () => {
  assert.equal(courseTimeText(course({ startSection: 1, endSection: 2 })), "09:00-10:20")
  assert.equal(courseTimeText(course({ startSection: 13, endSection: null })), "19:00-19:40")
  assert.equal(courseTimeText(course({ startSection: null })), "时间待定")
})

test("重叠课程并排，缺少定位信息的课程不进入周网格", () => {
  const courses = [
    course({ name: "课程甲" }),
    course({ name: "课程乙", endSection: 1 }),
    course({ name: "单双周课程", weeks: "1-3单周" }),
    course({ name: "无定位课程", weekday: null, startSection: null })
  ]

  const oddRows = buildWeekRows(courses, 1)
  const oddBlocks = oddRows[0].cells[0].blocks
  assert.equal(oddBlocks.length, 3)
  assert.equal(oddBlocks[0].width < 34, true)
  assert.equal(oddBlocks[1].width < 34, true)
  assert.equal(oddBlocks[0].color === oddBlocks[0].color, true)

  const evenRows = buildWeekRows(courses, 2)
  assert.equal(evenRows[0].cells[0].blocks.length, 2)
  assert.equal(evenRows[0].cells[0].blocks.some((block) => block.name === "单双周课程"), false)
})
