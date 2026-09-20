import { AcademicPeriod, ScheduleCourse } from "./models"

export interface WeekDay {
  index: number
  label: string
  date: string
  isToday: boolean
}

export interface WeekBlock extends ScheduleCourse {
  key: string
  courseIndex: number
  height: number
  left: number
  width: number
  color: string
}

export interface WeekCell {
  blocks: WeekBlock[]
}

export interface WeekRow {
  period: number
  start: string
  end: string
  cells: WeekCell[]
}

export interface WeekOption {
  week: number
  range: string
  selected: boolean
  current: boolean
}

const SECTION_TIMES: Array<[string, string]> = [
  ["09:00", "09:40"], ["09:40", "10:20"], ["10:40", "11:20"], ["11:20", "12:00"],
  ["12:30", "13:10"], ["13:10", "13:50"], ["14:00", "14:40"], ["14:40", "15:20"],
  ["15:30", "16:10"], ["16:10", "16:50"], ["17:00", "17:40"], ["17:40", "18:20"],
  ["19:00", "19:40"], ["19:40", "20:20"], ["20:30", "21:10"], ["21:10", "21:50"]
]

const DAY_LABELS = ["一", "二", "三", "四", "五", "六", "日"]
const COURSE_COLORS = ["#d9e9ff", "#dff3df", "#ffe5d1", "#eadfff", "#ffe0e8", "#d9f2f2"]
const ROW_HEIGHT_RPX = 92

export function parseScheduleDate(value: string): Date | null {
  const parts = value.split("-").map(Number)
  if (parts.length !== 3 || parts.some((part) => !Number.isInteger(part))) return null
  if (parts[0] < 2000 || parts[0] > 3000 || parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) return null
  const result = new Date(parts[0], parts[1] - 1, parts[2])
  if (Number.isNaN(result.getTime())) return null
  return result.getFullYear() === parts[0] && result.getMonth() === parts[1] - 1 && result.getDate() === parts[2]
    ? result
    : null
}

export function dateText(value: Date): string {
  const month = String(value.getMonth() + 1).padStart(2, "0")
  const day = String(value.getDate()).padStart(2, "0")
  return `${value.getFullYear()}-${month}-${day}`
}

export function mondayOf(value: Date): Date {
  const result = new Date(value.getFullYear(), value.getMonth(), value.getDate())
  const daysFromMonday = (result.getDay() + 6) % 7
  result.setDate(result.getDate() - daysFromMonday)
  return result
}

export function defaultFirstWeekStart(period: AcademicPeriod): Date {
  const seed = period.term === 1
    ? new Date(period.year, 8, 1)
    : new Date(period.year + 1, 2, 1)
  return mondayOf(seed)
}

export function weekFromDate(firstWeekStart: Date, date: Date): number {
  const difference = mondayOf(date).getTime() - mondayOf(firstWeekStart).getTime()
  return Math.min(30, Math.max(1, Math.floor(difference / 86400000 / 7) + 1))
}

export function dateForWeek(firstWeekStart: Date, week: number, dayIndex: number): Date {
  const date = new Date(firstWeekStart)
  date.setDate(date.getDate() + (week - 1) * 7 + dayIndex)
  return date
}

export function courseTimeText(course: ScheduleCourse): string {
  const startSection = course.startSection
  if (startSection === null || startSection < 1 || startSection > SECTION_TIMES.length) return "时间待定"
  const endSection = course.endSection === null
    ? startSection
    : Math.min(SECTION_TIMES.length, Math.max(startSection, course.endSection))
  return `${SECTION_TIMES[startSection - 1][0]}-${SECTION_TIMES[endSection - 1][1]}`
}

function weekRange(firstWeekStart: Date, week: number): string {
  const start = dateForWeek(firstWeekStart, week, 0)
  const end = dateForWeek(firstWeekStart, week, 6)
  return `${start.getMonth() + 1}/${start.getDate()}-${end.getMonth() + 1}/${end.getDate()}`
}

export function occursInWeek(spec: string | null, week: number): boolean {
  if (spec === null || spec.trim() === "") return true
  const normalized = spec.replace(/[（）]/g, "(").replace(/[，；、]/g, ",")
  let foundNumber = false
  for (const rawSegment of normalized.split(/[;,]/)) {
    const segment = rawSegment.trim()
    if (!segment) continue
    const odd = segment.includes("单")
    const even = segment.includes("双")
    if ((odd && week % 2 === 0) || (even && week % 2 === 1)) {
      foundNumber = true
      continue
    }
    const ranges = [...segment.matchAll(/(\d+)\s*-\s*(\d+)/g)]
    if (ranges.length > 0) {
      foundNumber = true
      if (ranges.some((match) => week >= Number(match[1]) && week <= Number(match[2]))) return true
      continue
    }
    for (const match of segment.matchAll(/\d+/g)) {
      foundNumber = true
      if (Number(match[0]) === week) return true
    }
  }
  return !foundNumber
}

function colorForCourse(name: string): string {
  let hash = 0
  for (const character of name) hash = (hash + character.charCodeAt(0)) % COURSE_COLORS.length
  return COURSE_COLORS[hash]
}

function validCourse(course: ScheduleCourse): boolean {
  return course.weekday !== null && course.weekday >= 1 && course.weekday <= 7 &&
    course.startSection !== null && course.startSection >= 1 && course.startSection <= 16
}

export function buildWeekRows(courses: ScheduleCourse[], week: number): WeekRow[] {
  const byDay: ScheduleCourse[][] = Array.from({ length: 7 }, () => [])
  for (const course of courses) {
    if (!validCourse(course) || !occursInWeek(course.weeks, week)) continue
    byDay[course.weekday! - 1].push(course)
  }
  const dayBlocks: WeekBlock[][] = byDay.map((items, dayIndex) => {
    const sorted = [...items].sort((left, right) =>
      (left.startSection! - right.startSection!) || left.name.localeCompare(right.name))
    const lanes: ScheduleCourse[][] = []
    const laneMap = new Map<ScheduleCourse, number>()
    for (const course of sorted) {
      const start = course.startSection!
      const end = Math.min(16, Math.max(start, course.endSection || start))
      let lane = 0
      while (lanes[lane]?.some((other) => {
        const otherEnd = Math.min(16, Math.max(other.startSection!, other.endSection || other.startSection!))
        return otherEnd >= start
      })) lane += 1
      if (!lanes[lane]) lanes[lane] = []
      lanes[lane].push(course)
      laneMap.set(course, lane)
    }
    const laneCount = Math.max(1, lanes.length)
    return sorted.map((course, index) => {
      const start = course.startSection!
      const end = Math.min(16, Math.max(start, course.endSection || start))
      const lane = laneMap.get(course) || 0
      const width = 100 / laneCount
      return {
        ...course,
        key: `${dayIndex}-${start}-${index}-${course.name}`,
        courseIndex: courses.indexOf(course),
        height: (end - start + 1) * ROW_HEIGHT_RPX - 8,
        left: lane * width + 1,
        width: width - 2,
        color: colorForCourse(course.name)
      }
    })
  })
  return SECTION_TIMES.map((time, index) => ({
    period: index + 1,
    start: time[0],
    end: time[1],
    cells: Array.from({ length: 7 }, (_, dayIndex) => ({
      blocks: dayBlocks[dayIndex].filter((course) => course.startSection === index + 1)
    }))
  }))
}

export function buildWeekDays(firstWeekStart: Date, week: number): WeekDay[] {
  const today = new Date()
  return DAY_LABELS.map((label, index) => {
    const date = dateForWeek(firstWeekStart, week, index)
    return {
      index,
      label: `周${label}`,
      date: `${date.getMonth() + 1}/${date.getDate()}`,
      isToday: dateText(date) === dateText(today)
    }
  })
}

export function buildWeekOptions(firstWeekStart: Date, selected: number, currentWeek: number): WeekOption[] {
  return Array.from({ length: 30 }, (_, index) => {
    const week = index + 1
    return { week, range: weekRange(firstWeekStart, week), selected: week === selected, current: week === currentWeek }
  })
}
