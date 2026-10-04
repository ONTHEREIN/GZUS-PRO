import { legalDocuments } from "../../utils/generated/legal"

Page({
  data: { title: "", html: "", error: "" },
  onLoad(options: Record<string, string | undefined>) {
    const type = options.type
    if (type !== "terms" && type !== "privacy") {
      this.setData({ error: "协议类型无效，请从登录页或我的页重新打开" })
      return
    }
    const document = legalDocuments[type]
    this.setData({ title: document.title, html: document.html })
    wx.setNavigationBarTitle({ title: document.title })
  }
})
