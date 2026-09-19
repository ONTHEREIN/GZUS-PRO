import { resolveApiBaseUrl } from "./config"

interface ApiFailure {
  detail?: string | { code?: string; message?: string }
}

export class ApiRequestError extends Error {
  constructor(message: string, readonly statusCode: number, readonly code: string | null) {
    super(message)
    this.name = "ApiRequestError"
  }
}

type HttpMethod = NonNullable<WechatMiniprogram.RequestOption["method"]>
export type ResponseParser<T> = (value: unknown) => T

/** 本地只保存短期会话 ID；学校 Cookie 与办事大厅 Token 永不落盘。 */
const SESSION_KEY = "auth.sessionId"

function sessionId(): string {
  return wx.getStorageSync(SESSION_KEY) as string
}

/**
 * 失败文案。
 *
 * 服务端 detail 已经区分了「凭据错误 / 会话过期 / 被管理员下线」，直接透传比统一
 * 兜底更准确。只有在没有 detail 时才按「本次是否携带会话」区分：
 * 携带会话的 401 是会话失效，未携带会话的 401（登录接口）是账号或密码错误。
 */
function messageForFailure(data: unknown, statusCode: number, hadSession: boolean): string {
  if (typeof data === "object" && data !== null && "detail" in data) {
    const detail = (data as ApiFailure).detail
    if (typeof detail === "string" && detail) return detail
    if (typeof detail === "object" && detail !== null && typeof detail.message === "string") {
      return detail.message
    }
  }
  if (statusCode === 401) {
    return hadSession ? "登录已失效，请重新登录" : "账号或密码错误"
  }
  return `请求失败（${statusCode}）`
}

function messageForNetworkFailure(errMsg: string): string {
  if (/url not in domain list/i.test(errMsg)) {
    const legalDomain = resolveApiBaseUrl().replace(/\/api\/?$/, "")
    return `微信未配置请求合法域名，请在后台加入 ${legalDomain}`
  }
  return errMsg || "网络连接失败"
}

export function request<T>(
  method: HttpMethod,
  path: string,
  data: object | undefined,
  parse: ResponseParser<T>
): Promise<T> {
  const sentSessionId = sessionId()
  const hadSession = Boolean(sentSessionId)

  return new Promise((resolve, reject) => {
    wx.request({
      url: `${resolveApiBaseUrl()}${path}`,
      method,
      data,
      header: {
        "Content-Type": "application/json",
        "X-Client-Platform": "wechat-mini-program",
        "X-Session-Id": sentSessionId
      },
      success(response) {
        // 只有携带过会话的 401 才意味着会话失效。登录接口本身返回的 401 属于
        // 凭据错误，此时本地并没有需要清理的会话。
        if (response.statusCode === 401 && hadSession) {
          wx.removeStorageSync(SESSION_KEY)
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            resolve(parse(response.data))
          } catch (error) {
            reject(error instanceof Error ? error : new Error("服务器响应格式无效"))
          }
          return
        }
        const failureCode = typeof response.data === "object" && response.data !== null &&
          "detail" in response.data && typeof (response.data as ApiFailure).detail === "object" &&
          (response.data as ApiFailure).detail !== null
          ? ((response.data as { detail: { code?: string } }).detail.code || null)
          : null
        reject(new ApiRequestError(messageForFailure(response.data, response.statusCode, hadSession), response.statusCode, failureCode))
      },
      fail(error) {
        reject(new Error(messageForNetworkFailure(error.errMsg)))
      }
    })
  })
}

export function get<T>(path: string, parse: ResponseParser<T>): Promise<T> {
  return request<T>("GET", path, undefined, parse)
}

export function post<T>(path: string, data: object, parse: ResponseParser<T>): Promise<T> {
  return request<T>("POST", path, data, parse)
}

export function put<T>(path: string, data: object, parse: ResponseParser<T>): Promise<T> {
  return request<T>("PUT", path, data, parse)
}

export function remove<T>(path: string, parse: ResponseParser<T>): Promise<T> {
  return request<T>("DELETE", path, undefined, parse)
}

export function requireSession(): boolean {
  if (sessionId()) return true
  wx.reLaunch({ url: "/pages/login/index" })
  return false
}
