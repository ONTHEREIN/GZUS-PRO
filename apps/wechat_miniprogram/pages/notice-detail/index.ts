import { ApiRequestError, get, requireSession } from "../../utils/api"
import { resolveApiBaseUrl } from "../../utils/config"
import { NoticeItem } from "../../utils/models"
import { parseNoticeDetail, parseNotices } from "../../utils/parsers"
import { noticePlainText, resolveNoticeCover } from "../../utils/notices"

Page({
  data: { item: null as NoticeItem | null, title: "", date: "", sourceLabel: "", contentLabel: "", content: "", coverUrl: "", coverError: "", loading: true, error: "" },

  onLoad() {
    if (!requireSession()) return
    const channel = this.getOpenerEventChannel()
    if (!channel.on) {
      this.setData({ loading: false, error: "未收到通知数据，请返回通知列表重新打开" })
      return
    }
    channel.on("notice", (value: object) => {
      try {
        const item = parseNotices([value])[0]
        const sources = { jwxt: "教务系统", ehall: "办事大厅", admin: "管理员发布", wechat: "公众号" }
        this.setData({ item, title: item.title, date: item.date || "", sourceLabel: sources[item.source] })
        if (item.coverUrl) {
          try { this.setData({ coverUrl: resolveNoticeCover(item.coverUrl, resolveApiBaseUrl()) }) }
          catch (error) { this.setData({ coverError: error instanceof Error ? error.message : "封面地址无效" }) }
        }
        void this.loadDetail()
      } catch (error) {
        this.setData({ loading: false, error: error instanceof Error ? error.message : "通知数据无效" })
      }
    })
  },

  async loadDetail() {
    const item = this.data.item
    if (!item || !requireSession()) return
    this.setData({ loading: true, error: "" })
    if (item.source !== "jwxt" || !item.url) {
      this.setData({ content: item.summary || "", contentLabel: item.source === "admin" ? "发布说明" : "通知摘要", loading: false })
      return
    }
    try {
      const detail = await get(`/notices/detail?url=${encodeURIComponent(item.url)}`, parseNoticeDetail)
      this.setData({ title: detail.title || item.title, date: detail.date || item.date || "", content: noticePlainText(detail.contentHtml), contentLabel: "通知正文" })
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "通知详情加载失败" })
      if (error instanceof ApiRequestError && error.statusCode === 401) requireSession()
    } finally {
      this.setData({ loading: false })
    }
  },

  onCoverError() { this.setData({ coverError: "通知封面加载失败", coverUrl: "" }) },

  copyOriginal() {
    const url = this.data.item?.url
    if (!url) return
    wx.setClipboardData({ data: url, fail(error) { wx.showToast({ title: error.errMsg, icon: "none" }) } })
  }
})
