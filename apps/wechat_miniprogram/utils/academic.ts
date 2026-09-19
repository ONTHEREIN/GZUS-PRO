import { get, put } from "./api"
import { AcademicPeriod } from "./models"
import { parseAcademicPeriod } from "./parsers"

const PERIOD_KEY = "academic.period"

export function academicPeriodNow(): AcademicPeriod {
  const now = new Date()
  const year = now.getMonth() >= 7 ? now.getFullYear() : now.getFullYear() - 1
  const term: 1 | 2 = now.getMonth() >= 7 || now.getMonth() === 0 ? 1 : 2
  return { year, term }
}

export function academicPeriodLabel(period: AcademicPeriod): string {
  return `${period.year}–${period.year + 1} 学年 第${period.term}学期`
}

export function periodQuery(period: AcademicPeriod): string {
  return `?year=${period.year}&term=${period.term}`
}

export async function syncAcademicPeriod(): Promise<AcademicPeriod> {
  const remote = await get<AcademicPeriod | null>("/settings/academic-period", parseAcademicPeriod)
  if (remote !== null) {
    wx.setStorageSync(PERIOD_KEY, remote)
    return remote
  }
  const derived = academicPeriodNow()
  return saveAcademicPeriod(derived)
}

export async function saveAcademicPeriod(period: AcademicPeriod): Promise<AcademicPeriod> {
  const saved = await put<AcademicPeriod>("/settings/academic-period", period, parseAcademicPeriodRequired)
  wx.setStorageSync(PERIOD_KEY, saved)
  return saved
}

function parseAcademicPeriodRequired(value: unknown): AcademicPeriod {
  const parsed = parseAcademicPeriod(value)
  if (parsed === null) throw new Error("服务端未返回已保存的学年学期")
  return parsed
}

export function clearAcademicPeriod(): void {
  wx.removeStorageSync(PERIOD_KEY)
}
