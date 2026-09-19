import { get, requireSession } from "../../utils/api"
import { academicPeriodLabel, periodQuery, syncAcademicPeriod } from "../../utils/academic"
import { ExamItem } from "../../utils/models"
import { parseExams } from "../../utils/parsers"

Page({
  data: { loading: true, error: "", exams: [] as ExamItem[], periodLabel: "", requestVersion: 0 },

  onShow() {
    if (requireSession()) this.loadExams()
  },

  async onPullDownRefresh() {
    await this.loadExams()
    wx.stopPullDownRefresh()
  },

  async loadExams() {
    const requestVersion = this.data.requestVersion + 1
    this.setData({ loading: true, error: "", requestVersion })
    try {
      const period = await syncAcademicPeriod()
      const exams = await get<ExamItem[]>(`/exams${periodQuery(period)}`, parseExams)
      if (this.data.requestVersion !== requestVersion) return
      exams.sort((left, right) => left.date.localeCompare(right.date))
      this.setData({ exams, periodLabel: academicPeriodLabel(period) })
    } catch (error) {
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ error: error instanceof Error ? error.message : "考试加载失败" })
    } finally {
      if (this.data.requestVersion === requestVersion) this.setData({ loading: false })
    }
  }
})
