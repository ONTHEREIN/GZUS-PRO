import { acceptLegal, hasAcceptedLegal } from "../../utils/legal"
import { ApiRequestError, post } from "../../utils/api"
import { syncAcademicPeriod } from "../../utils/academic"
import { LoginResponse } from "../../utils/models"
import { parseLogin, parseWechatBindingResponse } from "../../utils/parsers"
import { confirmWechatBinding, requestWechatCode } from "../../utils/wechat"

Page({
  data: {
    agreed: false,
    existingSession: false,
    account: "",
    password: "",
    submitting: false,
    wechatSubmitting: false,
    error: ""
  },

  onShow() {
    this.setData({ agreed: hasAcceptedLegal(), existingSession: Boolean(wx.getStorageSync("auth.sessionId")) })
    if (wx.getStorageSync("auth.sessionId") && hasAcceptedLegal()) {
      wx.switchTab({ url: "/pages/home/index" })
    }
  },

  onAccountInput(event: WechatMiniprogram.Input) {
    this.setData({ account: event.detail.value, error: "" })
  },

  onPasswordInput(event: WechatMiniprogram.Input) {
    this.setData({ password: event.detail.value, error: "" })
  },

  onAgreementChange(event: WechatMiniprogram.CheckboxGroupChange) {
    this.setData({ agreed: event.detail.value.includes("agree"), error: "" })
  },

  openTerms() { wx.navigateTo({ url: "/pages/legal/index?type=terms" }) },
  openPrivacy() { wx.navigateTo({ url: "/pages/legal/index?type=privacy" }) },

  async continueSession() {
    if (!this.data.agreed) {
      this.setData({ error: "请先阅读并同意用户服务协议和隐私政策" })
      return
    }
    if (this.data.submitting) return
    acceptLegal()
    this.setData({ submitting: true, error: "" })
    try {
      await syncAcademicPeriod()
      wx.switchTab({ url: "/pages/home/index" })
    } catch (error) {
      this.setData({ existingSession: Boolean(wx.getStorageSync("auth.sessionId")), error: error instanceof Error ? error.message : "会话恢复失败，请重新登录" })
    } finally {
      this.setData({ submitting: false })
    }
  },

  async submit() {
    if (this.data.submitting || this.data.wechatSubmitting) return
    if (!this.data.agreed) {
      this.setData({ error: "请先阅读并同意用户服务协议和隐私政策" })
      return
    }

    const account = this.data.account.trim()
    const password = this.data.password
    if (!account || !password) {
      this.setData({ error: "请输入学号和密码" })
      return
    }
    acceptLegal()
    this.setData({ submitting: true, error: "" })
    try {
      const result = await post<LoginResponse>("/mini/auth/login", { account, password }, parseLogin)
      wx.setStorageSync("auth.sessionId", result.sessionId)
      wx.setStorageSync("auth.studentName", result.studentName)
      wx.setStorageSync("auth.studentId", result.studentId)
      this.setData({ existingSession: true, password: "" })
      await syncAcademicPeriod()
      await this.offerWechatBinding()
      wx.switchTab({ url: "/pages/home/index" })
    } catch (error) {
      this.setData({ existingSession: Boolean(wx.getStorageSync("auth.sessionId")), error: error instanceof Error ? error.message : "登录失败，请稍后重试" })
    } finally {
      this.setData({ submitting: false })
    }
  },

  async wechatLogin() {
    if (this.data.submitting || this.data.wechatSubmitting) return
    if (!this.data.agreed) {
      this.setData({ error: "请先阅读并同意用户服务协议和隐私政策" })
      return
    }
    acceptLegal()
    this.setData({ wechatSubmitting: true, error: "" })
    try {
      const code = await requestWechatCode()
      const result = await post<LoginResponse>("/mini/auth/wechat-login", { code }, parseLogin)
      wx.setStorageSync("auth.sessionId", result.sessionId)
      wx.setStorageSync("auth.studentName", result.studentName)
      wx.setStorageSync("auth.studentId", result.studentId)
      this.setData({ existingSession: true, password: "" })
      await syncAcademicPeriod()
      wx.switchTab({ url: "/pages/home/index" })
    } catch (error) {
      const message = error instanceof ApiRequestError && error.code === "wechat_not_bound"
        ? "当前微信尚未绑定，请先使用学号密码登录"
        : error instanceof Error ? error.message : "微信登录失败，请稍后重试"
      this.setData({ existingSession: Boolean(wx.getStorageSync("auth.sessionId")), error: message })
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
