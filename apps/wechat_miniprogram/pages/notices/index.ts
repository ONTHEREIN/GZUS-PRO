import { get, requireSession } from "../../utils/api"
import { NoticeItem } from "../../utils/models"
import { parseNotices } from "../../utils/parsers"

Page({
  data: { loading: true, error: "", notices: [] as NoticeItem[] },

  onShow() {
    if (requireSession()) this.loadNotices()
  },

  async onPullDownRefresh() {
    await this.loadNotices()
    wx.stopPullDownRefresh()
  },

  async loadNotices() {
    this.setData({ loading: true, error: "" })
    try {
      const notices = await get<NoticeItem[]>("/notices", parseNotices)
      this.setData({ notices })
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "通知加载失败" })
    } finally {
      this.setData({ loading: false })
    }
  }
})
