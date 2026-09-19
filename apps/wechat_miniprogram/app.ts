import { syncAcademicPeriod } from "./utils/academic"

App({
  onShow() {
    if (!wx.getStorageSync("auth.sessionId")) return
    void syncAcademicPeriod().catch((error) => {
      console.warn("小程序前台同步学年学期失败", { error })
    })
  }
})
