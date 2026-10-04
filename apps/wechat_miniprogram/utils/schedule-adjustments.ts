import { get } from "./api"
import { AcademicPeriod, ScheduleCourse } from "./models"
import { parseScheduleDate } from "./schedule"

export interface AdjustmentMove {
  sourceDate: string
  targetDate: string
  sourceStart: number
  sourceEnd: number
  targetStart: number
}

export interface AdjustmentRecord {
  clientId: string
  year: number
  term: number
  sourceDate: string
  targetDate: string
  sourceOccurrenceKeys: string[]
  targetConflictKeys: string[]
  conflictMode: "swap" | "replaceConflicts" | "coexist"
  moves: AdjustmentMove[]
  status: "active" | "restored" | "archived"
  revision: number
}

export interface DatedCourse extends ScheduleCourse {
  groupId?: string
  date: string
  itemKey: string
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("调课响应格式无效")
  return value as Record<string, unknown>
}
function text(value: unknown): string {
  if (typeof value !== "string") throw new Error("调课文本字段无效")
  return value
}
function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value)) throw new Error("调课数字字段无效")
  return value
}
function date(value: unknown): string {
  const result = text(value)
  if (!parseScheduleDate(result)) throw new Error("调课日期字段无效")
  return result
}
function strings(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error("调课课程编号字段无效")
  return value.map(text)
}

export function parseAdjustment(value: unknown): AdjustmentRecord {
  const row = object(value)
  if (!["swap", "replaceConflicts", "coexist"].includes(text(row.conflictMode)) ||
      !["active", "restored", "archived"].includes(text(row.status))) throw new Error("调课状态无效")
  if (!Array.isArray(row.moves)) throw new Error("调课配对列表无效")
  return {
    clientId: text(row.clientId), year: integer(row.year), term: integer(row.term),
    sourceDate: date(row.sourceDate), targetDate: date(row.targetDate),
    sourceOccurrenceKeys: strings(row.sourceOccurrenceKeys), targetConflictKeys: strings(row.targetConflictKeys),
    conflictMode: row.conflictMode as AdjustmentRecord["conflictMode"], status: row.status as AdjustmentRecord["status"],
    revision: integer(row.revision), moves: row.moves.map((value) => {
      const move = object(value)
      return { sourceDate: date(move.sourceDate), targetDate: date(move.targetDate),
        sourceStart: integer(move.sourceStart), sourceEnd: integer(move.sourceEnd), targetStart: integer(move.targetStart) }
    })
  }
}

export function parseAdjustments(value: unknown): AdjustmentRecord[] {
  if (!Array.isArray(value)) throw new Error("调课记录列表无效")
  return value.map(parseAdjustment)
}

export function parseDatedCourses(value: unknown): DatedCourse[] {
  if (!Array.isArray(value)) throw new Error("生效课表列表无效")
  return value.map((value) => {
    const row = object(value)
    return { name: text(row.name), teacher: text(row.teacher), classroom: text(row.classroom),
      weekday: integer(row.weekday), startSection: integer(row.startSection), endSection: integer(row.endSection),
      weeks: String(integer(row.week)), date: date(row.date), itemKey: text(row.itemKey), ...(row.groupId == null ? {} : {groupId: text(row.groupId)}) }
  })
}

export function fetchDatedCourses(period: AcademicPeriod, firstWeekStart: string, refresh: boolean): Promise<DatedCourse[]> {
  return get(`/schedule/effective?year=${period.year}&term=${period.term}&firstWeekStart=${firstWeekStart}&refresh=${refresh}`, parseDatedCourses)
}

export function pairedMoves(sources: string[], targets: string[], start: number, end: number, targetStart: number): AdjustmentMove[] {
  if (!sources.length || sources.length !== targets.length) throw new Error("请选择数量相同的两组日期")
  const all = [...sources, ...targets]
  if (all.some((value) => !parseScheduleDate(value)) || new Set(all).size !== all.length) throw new Error("日期无效或重复，两组日期不能交叉")
  if (sources.length > 60) throw new Error("一次最多支持 60 组日期")
  if (![start, end, targetStart].every(Number.isInteger) || start < 1 || end < start || targetStart < 1 || end > 16 || targetStart + end - start > 16) throw new Error("节次区间无效，目标结束节次不能超过第 16 节")
  const sorted = [...sources].sort()
  const destinations = [...targets].sort()
  return sorted.map((sourceDate, index) => ({ sourceDate, targetDate: destinations[index], sourceStart: start, sourceEnd: end, targetStart }))
}

/** 按课程位置归并日期实例，周课表与全部课程均保留准确的生效周次。 */
export function groupDatedCourses(courses: DatedCourse[]): ScheduleCourse[] {
  const grouped = new Map<string, ScheduleCourse>()
  for (const course of courses) {
    const key = JSON.stringify([course.name, course.teacher, course.classroom, course.weekday, course.startSection, course.endSection])
    const existing = grouped.get(key)
    const weeks = new Set([...(existing?.weeks?.split(",") || []), course.weeks!])
    grouped.set(key, { name: course.name, teacher: course.teacher, classroom: course.classroom,
      weekday: course.weekday, startSection: course.startSection, endSection: course.endSection,
      occurrenceKeys: { ...existing?.occurrenceKeys, [course.date]: [...(existing?.occurrenceKeys?.[course.date] || []), course.itemKey] },
      weeks: [...weeks].sort((left, right) => Number(left) - Number(right)).join(",") })
  }
  return [...grouped.values()]
}
