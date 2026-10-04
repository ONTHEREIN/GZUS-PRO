import { get, post, put, remove, requireSession } from "../../utils/api"
import { NoticeItem } from "../../utils/models"
import { parseNotices } from "../../utils/parsers"

import { NotificationConfig, PersonalReminder, loadNotificationConfig, notificationType, parseNotificationConfig, parseReminders, reminderDestination, subscribeNext } from "../../utils/notifications"
import { requestWechatCode } from "../../utils/wechat"

Page({
  data: { loading: true, error: "", notices: [] as NoticeItem[],
    section: "school", reminders: [] as PersonalReminder[], reminderLoading: false, reminderError: "",
    config: null as NotificationConfig | null, settingsVisible: false, busy: false,
    account: "", password: "", backgroundConsent: false },

  onShow() {
    if (requireSession()) {
      this.loadNotices()
      this.loadReminders()
    }
  },

  showSchool() { this.setData({ section: "school" }) },
  showPersonal() { this.setData({ section: "personal" }) },
  toggleSettings() { this.setData({ settingsVisible: !this.data.settingsVisible }) },
  openProfile() { wx.switchTab({ url: "/pages/profile/index" }) },
  onAccountInput(event: WechatMiniprogram.Input) { this.setData({ account: event.detail.value }) },
  onPasswordInput(event: WechatMiniprogram.Input) { this.setData({ password: event.detail.value }) },
  onConsentChange(event: WechatMiniprogram.CheckboxGroupChange) { this.setData({ backgroundConsent: event.detail.value.includes("consent") }) },

  async loadReminders() {
    this.setData({ reminderLoading: true, reminderError: "" })
    try {
      const [reminders, config] = await Promise.all([get("/notifications/events", parseReminders), loadNotificationConfig()])
      this.setData({ reminders, config, account: wx.getStorageSync("auth.studentId") || "" })
    } catch (error) {
      this.setData({ reminderError: error instanceof Error ? error.message : "个人提醒加载失败" })
    } finally { this.setData({ reminderLoading: false }) }
  },

  async openReminder(event: WechatMiniprogram.TouchEvent) {
    const item = this.data.reminders[Number(event.currentTarget.dataset.index)]
    if (!item) throw new Error("提醒不存在，请刷新列表")
    try {
      await post(`/notifications/events/${encodeURIComponent(item.id)}/read`, {}, (value) => {
        if (typeof value !== "object" || value === null || !("status" in value) || value.status !== "ok") throw new Error("标记已读失败")
        return value
      })
      this.setData({ reminders: this.data.reminders.map((row) => row.id === item.id ? { ...row, readAt: new Date().toISOString() } : row) })
      const destination = reminderDestination(item.type)
      if (destination.tab) wx.switchTab({ url: destination.url })
      else wx.navigateTo({ url: destination.url })
    } catch (error) { this.setData({ reminderError: error instanceof Error ? error.message : "提醒打开失败" }) }
  },

  async changePreference(event: WechatMiniprogram.SwitchChange) {
    if (this.data.busy) return
    this.setData({ busy: true, reminderError: "" })
    try {
      const type = notificationType(event.currentTarget.dataset.type)
      const code = await requestWechatCode()
      const config = await put("/mini/notifications/preference", { type, enabled: event.detail.value, code }, parseNotificationConfig)
      this.setData({ config })
    } catch (error) { this.setData({ reminderError: error instanceof Error ? error.message : "提醒开关保存失败" }) }
    finally { this.setData({ busy: false }) }
  },

  async subscribe(event: WechatMiniprogram.TouchEvent) {
    if (this.data.busy) return
    const setting = this.data.config?.settings[Number(event.currentTarget.dataset.index)]
    if (!setting) throw new Error("提醒设置不存在")
    this.setData({ busy: true, reminderError: "" })
    try { this.setData({ config: await subscribeNext(setting) }) }
    catch (error) { this.setData({ reminderError: error instanceof Error ? error.message : "订阅失败" }) }
    finally { this.setData({ busy: false }) }
  },

  async authorizeBackground() {
    if (this.data.busy) return
    if (!this.data.backgroundConsent) { this.setData({ reminderError: "请先同意后台检测授权" }); return }
    const account = this.data.account.trim()
    const password = this.data.password
    if (!account || !password) { this.setData({ reminderError: "请输入学校学号和密码以授权后台检测" }); return }
    this.setData({ busy: true, password: "", reminderError: "" })
    try {
      const code = await requestWechatCode()
      this.setData({ config: await post("/mini/notifications/background", { account, password, code, consent: true }, parseNotificationConfig) })
    } catch (error) { this.setData({ reminderError: error instanceof Error ? error.message : "后台授权失败" }) }
    finally { this.setData({ busy: false, password: "" }) }
  },

  async disableBackground() {
    if (this.data.busy) return
    this.setData({ busy: true, reminderError: "" })
    try { this.setData({ config: await remove("/mini/notifications/background", parseNotificationConfig) }) }
    catch (error) { this.setData({ reminderError: error instanceof Error ? error.message : "后台授权关闭失败" }) }
    finally { this.setData({ busy: false }) }
  },

  async onPullDownRefresh() {
    await Promise.all([this.loadNotices(), this.loadReminders()])
    wx.stopPullDownRefresh()
  },

  openNotice(event: WechatMiniprogram.TouchEvent) {
    const item = this.data.notices[Number(event.currentTarget.dataset.index)]
    if (!item) throw new Error("通知条目不存在，请刷新列表")
    wx.navigateTo({
      url: "/pages/notice-detail/index",
      success(result) { result.eventChannel.emit("notice", item) }
    })
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
