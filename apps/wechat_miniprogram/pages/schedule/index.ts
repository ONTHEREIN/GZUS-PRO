import { get, put, requireSession } from "../../utils/api"
import {
  academicPeriodLabel,
  academicPeriodNow,
  periodQuery,
  saveAcademicPeriod,
  syncAcademicPeriod
} from "../../utils/academic"
import { AcademicPeriod, ScheduleCourse, ScheduleSettings } from "../../utils/models"
import { parseScheduleCourses, parseScheduleSettings } from "../../utils/parsers"
import {
  buildWeekDays,
  buildWeekOptions,
  buildWeekRows,
  defaultFirstWeekStart,
  dateText,
  mondayOf,
  parseScheduleDate,
  weekFromDate,
  WeekDay,
  WeekOption,
  WeekRow
} from "../../utils/schedule"

Page({
  data: {
    loading: true,
    error: "",
    courses: [] as ScheduleCourse[],
    rows: [] as WeekRow[],
    days: [] as WeekDay[],
    weekOptions: [] as WeekOption[],
    periodLabel: "",
    firstWeekStart: "",
    week: 1,
    currentWeek: 1,
    weekTitle: "第1周",
    mode: "week" as "week" | "all",
    periodPickerRange: [[], ["第1学期", "第2学期"]] as string[][],
    periodPickerValue: [0, 0] as number[],
    requestVersion: 0,
    showWeekPicker: false,
    selectedCourse: null as ScheduleCourse | null,
    period: null as AcademicPeriod | null
  },

  onLoad() {
    if (requireSession()) this.loadCourses(false)
  },

  async onPullDownRefresh() {
    await this.loadCourses(true)
    wx.stopPullDownRefresh()
  },

  async loadCourses(refresh: boolean) {
    const requestVersion = this.data.requestVersion + 1
    this.setData({ loading: true, error: "", requestVersion })
    try {
      const period = await syncAcademicPeriod()
      const fallback = defaultFirstWeekStart(period)
      const path = `/schedule${periodQuery(period)}${refresh ? "&refresh=true" : ""}`
      // 学期设置只影响周次显示，不能阻塞核心课表请求。首页和 App 前台同步也可能
      // 同时触发设置请求，课表先发起自己的请求，避免首屏被非关键请求拖住。
      const coursesPromise = get<ScheduleCourse[]>(path, parseScheduleCourses)
      const settingsPromise = get<ScheduleSettings>("/settings/schedule", parseScheduleSettings)
        .catch(() => null)
      const courses = await coursesPromise

      const applySchedule = (firstWeekStart: Date): boolean => {
        if (this.data.requestVersion !== requestVersion) return false
        const currentWeek = weekFromDate(firstWeekStart, new Date())
        const isCurrentPeriod = period.year === academicPeriodNow().year && period.term === academicPeriodNow().term
        const initialWeek = isCurrentPeriod ? currentWeek : 1
        this.setData({
          period,
          periodLabel: academicPeriodLabel(period),
          courses,
          firstWeekStart: dateText(firstWeekStart),
          currentWeek,
          week: initialWeek,
          weekTitle: `第${initialWeek}周`,
          periodPickerRange: this.periodPickerRange(period),
          periodPickerValue: this.periodPickerValue(period),
          rows: buildWeekRows(courses, initialWeek),
          days: buildWeekDays(firstWeekStart, initialWeek),
          weekOptions: this.makeWeekOptions(firstWeekStart, initialWeek, currentWeek),
          loading: false
        })
        return true
      }

      // 课程接口返回后立即结束加载态；第一周配置只负责调整周次，不应挡住课表首屏。
      if (!applySchedule(fallback)) return
      const settings = await settingsPromise
      if (settings === null) return
      const configured = settings.firstWeeks[`${period.year}-${period.term}`]
      const firstWeekStart = mondayOf(parseScheduleDate(configured || "") || fallback)
      if (dateText(firstWeekStart) !== dateText(fallback)) applySchedule(firstWeekStart)
    } catch (error) {
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ error: error instanceof Error ? error.message : "课表加载失败" })
    } finally {
      if (this.data.requestVersion === requestVersion) this.setData({ loading: false })
    }
  },

  makeWeekOptions(firstWeekStart: Date, selected: number, currentWeek: number): WeekOption[] {
    return buildWeekOptions(firstWeekStart, selected, currentWeek)
  },

  periodPickerRange(period: AcademicPeriod): string[][] {
    const now = academicPeriodNow()
    const firstYear = Math.max(2000, Math.min(period.year, now.year) - 4)
    const lastYear = Math.min(3000, Math.max(period.year, now.year) + 1)
    return [
      Array.from({ length: lastYear - firstYear + 1 }, (_, index) => String(firstYear + index)),
      ["第1学期", "第2学期"]
    ]
  },

  periodPickerValue(period: AcademicPeriod): number[] {
    const years = this.periodPickerRange(period)[0]
    return [years.indexOf(String(period.year)), period.term - 1]
  },

  async changeAcademicPeriod(event: WechatMiniprogram.PickerChange) {
    const values = event.detail.value as number[]
    const years = this.data.periodPickerRange[0]
    const year = Number(years[values[0]])
    const term = (values[1] + 1) as 1 | 2
    if (!Number.isInteger(year) || (this.data.period?.year === year && this.data.period.term === term)) return
    try {
      await saveAcademicPeriod({ year, term })
      await this.loadCourses(false)
      wx.showToast({ title: "学期已同步", icon: "success" })
    } catch (error) {
      wx.showToast({ title: error instanceof Error ? error.message : "学期同步失败", icon: "none" })
    }
  },

  updateWeek(week: number) {
    const firstWeekStart = parseScheduleDate(this.data.firstWeekStart)
    if (firstWeekStart === null) return
    const selected = Math.min(30, Math.max(1, week))
    this.setData({
      week: selected,
      weekTitle: `第${selected}周`,
      rows: buildWeekRows(this.data.courses, selected),
      days: buildWeekDays(firstWeekStart, selected),
      weekOptions: this.makeWeekOptions(firstWeekStart, selected, this.data.currentWeek),
      showWeekPicker: false
    })
  },

  previousWeek() { this.updateWeek(this.data.week - 1) },
  nextWeek() { this.updateWeek(this.data.week + 1) },
  backToCurrentWeek() { this.updateWeek(this.data.currentWeek) },
  openWeekPicker() { this.setData({ showWeekPicker: true }) },
  closeWeekPicker() { this.setData({ showWeekPicker: false }) },

  stopModalTap() {},

  selectWeek(event: WechatMiniprogram.BaseEvent) {
    const week = Number((event.currentTarget as { dataset: { week?: string | number } }).dataset.week)
    this.updateWeek(week)
  },

  setMode(event: WechatMiniprogram.BaseEvent) {
    const mode = ((event.currentTarget as { dataset: { mode?: string } }).dataset.mode || "week") as "week" | "all"
    this.setData({ mode })
  },

  showCourse(event: WechatMiniprogram.BaseEvent) {
    const index = Number((event.currentTarget as { dataset: { index?: string | number } }).dataset.index)
    const course = this.data.courses[index]
    if (course) this.setData({ selectedCourse: course })
  },

  closeCourse() { this.setData({ selectedCourse: null }) },

  async changeFirstWeek(event: WechatMiniprogram.PickerChange) {
    const period = this.data.period
    const selected = parseScheduleDate(String(event.detail.value))
    if (period === null || selected === null) return
    const monday = mondayOf(selected)
    try {
      await put("/settings/schedule", { firstWeeks: { [`${period.year}-${period.term}`]: dateText(monday) } }, parseScheduleSettings)
      const current = period.year === academicPeriodNow().year && period.term === academicPeriodNow().term
      const week = current ? weekFromDate(monday, new Date()) : this.data.week
      this.setData({
        firstWeekStart: dateText(monday),
        currentWeek: current ? week : this.data.currentWeek,
        week,
        weekTitle: `第${week}周`,
        rows: buildWeekRows(this.data.courses, week),
        days: buildWeekDays(monday, week),
        weekOptions: this.makeWeekOptions(monday, week, current ? week : this.data.currentWeek)
      })
      wx.showToast({ title: "第一周日期已同步", icon: "success" })
    } catch (error) {
      wx.showToast({ title: error instanceof Error ? error.message : "同步失败", icon: "none" })
    }
  }
})
