import { get, requireSession } from "../../utils/api"
import { academicPeriodLabel, periodQuery, syncAcademicPeriod } from "../../utils/academic"
import { AttendanceItem, AttendanceResponse } from "../../utils/models"
import { parseAttendance } from "../../utils/parsers"

Page({
  data: {
    loading: true,
    error: "",
    periodLabel: "",
    items: [] as AttendanceItem[],
    totals: {
      normal: 0,
      late: 0,
      leaveEarly: 0,
      absent: 0,
      leave: 0,
      total: 0
    },
    requestVersion: 0
  },

  onLoad() {
    if (requireSession()) this.loadAttendance()
  },

  async onPullDownRefresh() {
    await this.loadAttendance()
    wx.stopPullDownRefresh()
  },

  async loadAttendance() {
    const requestVersion = this.data.requestVersion + 1
    this.setData({ loading: true, error: "", requestVersion })
    try {
      const period = await syncAcademicPeriod()
      const response = await get<AttendanceResponse>(`/attendance${periodQuery(period)}`, parseAttendance)
      if (this.data.requestVersion !== requestVersion) return
      this.setData({
        items: response.items,
        totals: sumAttendance(response.items),
        periodLabel: academicPeriodLabel(period)
      })
    } catch (error) {
      if (this.data.requestVersion !== requestVersion) return
      this.setData({ error: error instanceof Error ? error.message : "考勤加载失败" })
    } finally {
      if (this.data.requestVersion === requestVersion) this.setData({ loading: false })
    }
  }
})

function sumAttendance(items: AttendanceItem[]) {
  return items.reduce(
    (totals, item) => ({
      normal: totals.normal + item.normal,
      late: totals.late + item.late,
      leaveEarly: totals.leaveEarly + item.leaveEarly,
      absent: totals.absent + item.absent,
      leave: totals.leave + item.leave,
      total: totals.total + item.total
    }),
    { normal: 0, late: 0, leaveEarly: 0, absent: 0, leave: 0, total: 0 }
  )
}
