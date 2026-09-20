import { get, requireSession } from "../../utils/api"
import { academicPeriodLabel, periodQuery, syncAcademicPeriod } from "../../utils/academic"
import { GradeItem } from "../../utils/models"
import { parseGrades } from "../../utils/parsers"

Page({
  data: { loading: true, error: "", grades: [] as GradeItem[], periodLabel: "", requestVersion: 0 },

  onLoad() {
    if (requireSession()) this.loadGrades()
  },

  async onPullDownRefresh() {
    await this.loadGrades()
    wx.stopPullDownRefresh()
  },

  async loadGrades() {
    const requestVersion = this.data.requestVersion + 1
    this.setData({ loading: true, error: "", requestVersion })
    try {
      const period = await syncAcademicPeriod()
      const grades = await get<GradeItem[]>(`/grades${periodQuery(period)}`, parseGrades)
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ grades, periodLabel: academicPeriodLabel(period) })
    } catch (error) {
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ error: error instanceof Error ? error.message : "成绩加载失败" })
    } finally {
      if (this.data.requestVersion === requestVersion) this.setData({ loading: false })
    }
  }
})
