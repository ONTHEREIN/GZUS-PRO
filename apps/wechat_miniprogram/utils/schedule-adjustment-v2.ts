import { get, post } from "./api"
import { AcademicPeriod } from "./models"
import { AdjustmentRecord, DatedCourse, parseAdjustment, parseAdjustments, parseDatedCourses } from "./schedule-adjustments"

export interface AdjustmentPair {
  itemId?: string
  sourceDate: string; targetDate: string; sourceStart: number; sourceEnd: number; targetStart: number
  sourceKeys: string[]; action: "move" | "swap" | "replace" | "choose"
}
export interface AdjustmentRequest {
  schemaVersion: 2 | 3; year: number; term: number; firstWeekStart: string; operation: "course" | "day" | "dayCover" | "partialDay"; pairs: AdjustmentPair[]
}
export interface PairPreview { pair: AdjustmentPair; before: DatedCourse[]; after: DatedCourse[]; conflicts: DatedCourse[]; labels: string[]; beforeCount: number; afterCount: number; conflictCount: number }
export interface AdjustmentPreview { fingerprint: string; ready: boolean; pairs: PairPreview[]; affectedCount: number; batchConflicts: string[]; before: DatedCourse[]; after: DatedCourse[] }
export interface AdjustmentMetadata { request: AdjustmentRequest; preview: AdjustmentPreview }
export interface RestorePreview { fingerprint: string; blockers: string[]; before: DatedCourse[]; after: DatedCourse[]; beforeCount: number; afterCount: number }
export interface AdjustmentHistory extends AdjustmentRecord { metadata: AdjustmentMetadata | null; createdAt: string | null }

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("新版调课响应不是对象")
  return value as Record<string, unknown>
}
function string(value: unknown): string { if (typeof value !== "string") throw new Error("新版调课文本字段无效"); return value }
function number(value: unknown): number { if (typeof value !== "number" || !Number.isInteger(value)) throw new Error("新版调课数字字段无效"); return value }
function list<T>(value: unknown, parse: (item: unknown) => T): T[] { if (!Array.isArray(value)) throw new Error("新版调课列表字段无效"); return value.map(parse) }
export function parsePair(value: unknown): AdjustmentPair {
  const p = record(value), action = string(p.action)
  if (!["move", "swap", "replace", "choose"].includes(action)) throw new Error("新版调课方式无效")
  return { ...(p.itemId == null ? {} : {itemId: string(p.itemId)}), sourceDate: string(p.sourceDate), targetDate: string(p.targetDate), sourceStart: number(p.sourceStart), sourceEnd: number(p.sourceEnd), targetStart: number(p.targetStart), sourceKeys: list(p.sourceKeys, string), action: action as AdjustmentPair["action"] }
}
export function parseRequest(value: unknown): AdjustmentRequest {
  const r = record(value)
  if (![2, 3].includes(Number(r.schemaVersion)) || !["course", "day", "dayCover", "partialDay"].includes(string(r.operation))) throw new Error("新版调课协议无效")
  return { schemaVersion: r.schemaVersion as 2 | 3, year: number(r.year), term: number(r.term), firstWeekStart: string(r.firstWeekStart), operation: r.operation as AdjustmentRequest["operation"], pairs: list(r.pairs, parsePair) }
}
export function parsePreview(value: unknown): AdjustmentPreview {
  const r = record(value)
  if (typeof r.ready !== "boolean") throw new Error("调课预览确认状态无效")
  return { fingerprint: string(r.fingerprint), ready: r.ready, affectedCount: number(r.affectedCount), batchConflicts: r.batchConflicts == null ? [] : list(r.batchConflicts, v=> {const c=record(v);return `${string(c.message)}：${parseDatedCourses(c.courses).map(o=>`${o.name} ${o.date} ${o.startSection}–${o.endSection}节`).join("；")}`}), before: parseDatedCourses(r.before || []), after: parseDatedCourses(r.after || []), pairs: list(r.pairs, (value) => { const p = record(value); const before = parseDatedCourses(p.before), after = parseDatedCourses(p.after), conflicts = parseDatedCourses(p.conflicts); return { beforeCount: before.length, afterCount: after.length, conflictCount: conflicts.length, pair: parsePair(p.pair), before, after, conflicts, labels: list(p.labels, string) } }) }
}
export function parseHistory(value: unknown): AdjustmentHistory[] {
  const basic = parseAdjustments(value)
  return list(value, (raw) => { const r = record(raw), index = basic.find((item) => item.clientId === r.clientId); if (!index) throw new Error("调课历史编号无效"); const metadata = r.metadata == null ? null : record(r.metadata); return { ...index, metadata: metadata ? { request: parseRequest(metadata.request), preview: parsePreview(metadata.preview) } : null, createdAt: r.createdAt == null ? null : string(r.createdAt) } })
}
export function parseRestore(value: unknown): RestorePreview { const r = record(value); const before = parseDatedCourses(r.before), after = parseDatedCourses(r.after); return { beforeCount: before.length, afterCount: after.length, fingerprint: string(r.fingerprint), blockers: list(r.blockers, string), before: parseDatedCourses(r.before), after: parseDatedCourses(r.after) } }
export function history(period: AcademicPeriod): Promise<AdjustmentHistory[]> { return get(`/settings/schedule/adjustments/v3?year=${period.year}&term=${period.term}`, parseHistory) }
export function preview(request: AdjustmentRequest): Promise<AdjustmentPreview> { return post("/settings/schedule/adjustments/v3/preview", request, parsePreview) }
export function commit(request: AdjustmentRequest, clientId: string, fingerprint: string): Promise<AdjustmentRecord> { return post("/settings/schedule/adjustments/v3", { ...request, clientId, fingerprint }, parseAdjustment) }
export function restorePreview(row: AdjustmentHistory, firstWeekStart: string): Promise<RestorePreview> { return post(`/settings/schedule/adjustments/v3/${encodeURIComponent(row.clientId)}/restore-preview`, { year: row.year, term: row.term, firstWeekStart, expectedRevision: row.revision, fingerprint: null }, parseRestore) }
export function restore(row: AdjustmentHistory, firstWeekStart: string, fingerprint: string): Promise<AdjustmentRecord> { return post(`/settings/schedule/adjustments/v3/${encodeURIComponent(row.clientId)}/restore`, { year: row.year, term: row.term, firstWeekStart, expectedRevision: row.revision, fingerprint }, parseAdjustment) }
