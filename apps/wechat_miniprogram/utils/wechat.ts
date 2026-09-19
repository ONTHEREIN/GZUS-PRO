export function requestWechatCode(): Promise<string> {
  return new Promise((resolve, reject) => {
    wx.login({
      success(result) {
        if (result.code) {
          resolve(result.code)
          return
        }
        reject(new Error("微信登录未返回有效凭证"))
      },
      fail(error) {
        reject(new Error(error.errMsg || "微信登录失败"))
      }
    })
  })
}

export function confirmWechatBinding(): Promise<boolean> {
  return new Promise((resolve) => {
    wx.showModal({
      title: "绑定微信",
      content: "绑定后可使用微信一键登录，是否绑定当前微信？",
      confirmText: "确认绑定",
      cancelText: "暂不绑定",
      success(result) {
        resolve(result.confirm === true)
      },
      fail() {
        resolve(false)
      }
    })
  })
}
