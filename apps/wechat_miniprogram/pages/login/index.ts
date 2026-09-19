import { ApiRequestError, post } from "../../utils/api"
import { syncAcademicPeriod } from "../../utils/academic"
import { LoginResponse } from "../../utils/models"
import { parseLogin, parseWechatBindingResponse } from "../../utils/parsers"
import { confirmWechatBinding, requestWechatCode } from "../../utils/wechat"

Page({
  data: {
    account: "",
    password: "",
    submitting: false,
    wechatSubmitting: false,
    error: ""
  },

  onShow() {
    if (wx.getStorageSync("auth.sessionId")) {
      wx.switchTab({ url: "/pages/home/index" })
    }
  },

  onAccountInput(event: WechatMiniprogram.Input) {
    this.setData({ account: event.detail.value, error: "" })
  },

  onPasswordInput(event: WechatMiniprogram.Input) {
    this.setData({ password: event.detail.value, error: "" })
  },

  async submit() {
    const account = this.data.account.trim()
    const password = this.data.password
    if (!account || !password) {
      this.setData({ error: "请输入学号和密码" })
      return
    }
    this.setData({ submitting: true, error: "" })
    try {
      const result = await post<LoginResponse>("/mini/auth/login", { account, password }, parseLogin)
      wx.setStorageSync("auth.sessionId", result.sessionId)
      wx.setStorageSync("auth.studentName", result.studentName)
      wx.setStorageSync("auth.studentId", result.studentId)
      await syncAcademicPeriod()
      await this.offerWechatBinding()
      wx.switchTab({ url: "/pages/home/index" })
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "登录失败，请稍后重试" })
    } finally {
      this.setData({ submitting: false })
    }
  },

  async wechatLogin() {
    if (this.data.submitting || this.data.wechatSubmitting) return
    this.setData({ wechatSubmitting: true, error: "" })
    try {
      const code = await requestWechatCode()
      const result = await post<LoginResponse>("/mini/auth/wechat-login", { code }, parseLogin)
      wx.setStorageSync("auth.sessionId", result.sessionId)
      wx.setStorageSync("auth.studentName", result.studentName)
      wx.setStorageSync("auth.studentId", result.studentId)
      await syncAcademicPeriod()
      wx.switchTab({ url: "/pages/home/index" })
    } catch (error) {
      const message = error instanceof ApiRequestError && error.code === "wechat_not_bound"
        ? "当前微信尚未绑定，请先使用学号密码登录"
        : error instanceof Error ? error.message : "微信登录失败，请稍后重试"
      this.setData({ error: message })
    } finally {
      this.setData({ wechatSubmitting: false })
    }
  },

  async offerWechatBinding() {
    if (!(await confirmWechatBinding())) return
    try {
      const code = await requestWechatCode()
      await post("/mini/auth/wechat-binding", { code }, parseWechatBindingResponse)
      wx.showToast({ title: "微信绑定成功", icon: "success" })
    } catch (error) {
      wx.showToast({ title: error instanceof Error ? error.message : "微信绑定失败", icon: "none" })
    }
  }
})
