import { get, requireSession } from "../../utils/api"
import { academicPeriodLabel, periodQuery, syncAcademicPeriod } from "../../utils/academic"
import { EcardSummary, ExamItem, ScheduleCourse, StudentInfo } from "../../utils/models"
import {
  parseEcardSummary,
  parseExams,
  parseScheduleCourses,
  parseStudentInfo
} from "../../utils/parsers"
import { courseTimeText } from "../../utils/schedule"

type HomeCourse = ScheduleCourse & { time: string }

Page({
  data: {
    loading: true,
    error: "",
    info: null as StudentInfo | null,
    courses: [] as HomeCourse[],
    exams: [] as ExamItem[],
    periodLabel: "",
    requestVersion: 0,

    // 水电余额模块单独维护状态：它依赖第三方一卡通服务，最容易失败，
    // 不能让它把首页其它模块一起拖垮。
    ecard: null as EcardSummary | null,
    ecardLoading: true,
    ecardError: ""
  },

  onLoad() {
    if (requireSession()) this.loadPage()
  },

  async onPullDownRefresh() {
    await this.loadPage()
    wx.stopPullDownRefresh()
  },

  async loadPage() {
    const requestVersion = this.data.requestVersion + 1
    this.setData({ loading: true, error: "", requestVersion })

    // 与核心数据并行发起，但各自独立结算。
    const ecardPromise = this.loadEcard()

    try {
      const period = await syncAcademicPeriod()
      const [info, courses, exams] = await Promise.all([
        get<StudentInfo>("/me", parseStudentInfo),
        get<ScheduleCourse[]>(`/schedule${periodQuery(period)}`, parseScheduleCourses),
        get<ExamItem[]>(`/exams${periodQuery(period)}`, parseExams)
      ])
      if (this.data.requestVersion !== requestVersion) return
      const homeCourses = courses.slice(0, 3).map((course) => ({
        ...course,
        time: courseTimeText(course)
      }))
      this.setData({ info, courses: homeCourses, exams: exams.slice(0, 2), periodLabel: academicPeriodLabel(period) })
    } catch (error) {
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ error: error instanceof Error ? error.message : "首页加载失败" })
    } finally {
      if (this.data.requestVersion === requestVersion) this.setData({ loading: false })
    }

    await ecardPromise
  },

  async loadEcard() {
    this.setData({ ecardLoading: true, ecardError: "" })
    try {
      const ecard = await get<EcardSummary>("/ecard/summary", parseEcardSummary)
      this.setData({ ecard })
    } catch (error) {
      // 只在卡片内提示，不设置页面级 error。
      this.setData({
        ecard: null,
        ecardError: error instanceof Error ? error.message : "水电余额加载失败"
      })
    } finally {
      this.setData({ ecardLoading: false })
    }
  },

  openSchedule() {
    wx.switchTab({ url: "/pages/schedule/index" })
  },

  openGrades() {
    wx.navigateTo({ url: "/pages/grades/index" })
  },

  openAttendance() {
    wx.navigateTo({ url: "/pages/attendance/index" })
  },

  openExams() {
    wx.navigateTo({ url: "/pages/exams/index" })
  },

  openEcard() {
    wx.navigateTo({ url: "/pages/ecard/index" })
  }
})
