import { get, post, remove, requireSession } from "../../utils/api"
import { clearAcademicPeriod } from "../../utils/academic"
import { StudentInfo } from "../../utils/models"
import { parseEmpty, parseStudentInfo, parseWechatBindingResponse, parseWechatBindingStatus } from "../../utils/parsers"
import { requestWechatCode } from "../../utils/wechat"

Page({
  data: {
    loading: true,
    error: "",
    info: null as StudentInfo | null,
    avatarText: "",
    wechatBound: false,
    bindingLoading: true,
    bindingAction: false
  },

  onShow() {
    if (requireSession()) this.loadProfile()
  },

  async loadProfile() {
    this.setData({ loading: true, error: "" })
    try {
      const info = await get<StudentInfo>("/me", parseStudentInfo)
      this.setData({ info, avatarText: info.name.slice(0, 1) })
      await this.loadWechatBinding()
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "个人信息加载失败" })
    } finally {
      this.setData({ loading: false })
    }
  },

  async loadWechatBinding() {
    this.setData({ bindingLoading: true })
    try {
      const status = await get("/mini/auth/wechat-binding", parseWechatBindingStatus)
      this.setData({ wechatBound: status.isBound })
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "微信绑定状态加载失败" })
    } finally {
      this.setData({ bindingLoading: false })
    }
  },

  async bindWechat() {
    if (this.data.bindingAction) return
    this.setData({ bindingAction: true })
    try {
      const code = await requestWechatCode()
      await post("/mini/auth/wechat-binding", { code }, parseWechatBindingResponse)
      this.setData({ wechatBound: true })
      wx.showToast({ title: "微信绑定成功", icon: "success" })
    } catch (error) {
      wx.showToast({ title: error instanceof Error ? error.message : "微信绑定失败", icon: "none" })
    } finally {
      this.setData({ bindingAction: false })
    }
  },

  unbindWechat() {
    if (this.data.bindingAction) return
    wx.showModal({
      title: "解除微信绑定",
      content: "解绑后将不能使用微信一键登录，确定继续吗？",
      confirmText: "解除绑定",
      success: (result) => {
        if (result.confirm) void this.performUnbindWechat()
      }
    })
  },

  async performUnbindWechat() {
    this.setData({ bindingAction: true })
    try {
      await remove("/mini/auth/wechat-binding", parseWechatBindingResponse)
      this.setData({ wechatBound: false })
      wx.showToast({ title: "已解除绑定", icon: "success" })
    } catch (error) {
      wx.showToast({ title: error instanceof Error ? error.message : "解绑失败", icon: "none" })
    } finally {
      this.setData({ bindingAction: false })
    }
  },

  async logout() {
    try {
      await post<Record<string, never>>("/auth/logout", {}, parseEmpty)
    } catch (error) {
      console.warn("小程序退出登录的服务端会话清理失败", { error })
    }
    wx.removeStorageSync("auth.sessionId")
    wx.removeStorageSync("auth.studentName")
    wx.removeStorageSync("auth.studentId")
    clearAcademicPeriod()
    wx.reLaunch({ url: "/pages/login/index" })
  }
})
