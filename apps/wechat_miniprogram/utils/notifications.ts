import { get, post } from "./api"
import { requestWechatCode } from "./wechat"

export const notificationTypes = ["exam_reminder", "grade_update", "course_reminder", "attendance_update", "ecard_reminder"] as const
export type NotificationType = typeof notificationTypes[number]

export interface PersonalReminder {
  id: string
  type: NotificationType
  title: string
  body: string
  createdAt: string
  readAt: string | null
}

export interface NotificationSetting {
  type: NotificationType
  label: string
  templateId: string | null
  enabled: boolean
  credits: number
  subscriptionStatus: string
  lastError: string | null
  statusText: string
  deliveryText: string | null
  deliveryError: string | null
}

export interface NotificationConfig {
  bound: boolean
  backgroundAuthorized: boolean
  backgroundSuspended: boolean
  lastCheckedAt: string | null
  lastError: string | null
  settings: NotificationSetting[]
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("提醒响应格式无效")
  return value as Record<string, unknown>
}
function text(value: unknown): string {
  if (typeof value !== "string") throw new Error("提醒文本字段无效")
  return value
}
function nullableText(value: unknown): string | null {
  return value === null ? null : text(value)
}
function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("提醒开关字段无效")
  return value
}
export function notificationType(value: unknown): NotificationType {
  if (!notificationTypes.includes(value as NotificationType)) throw new Error("提醒类型无效")
  return value as NotificationType
}

export function parseReminders(value: unknown): PersonalReminder[] {
  const response = object(value)
  if (!Array.isArray(response.events)) throw new Error("提醒列表字段无效")
  return Array.from(response.events, object).filter((row) => notificationTypes.includes(row.type as NotificationType)).map((row) => ({
    id: text(row.id), type: notificationType(row.type), title: text(row.title), body: text(row.body),
    createdAt: text(row.createdAt), readAt: nullableText(row.readAt)
  }))
}

export function parseNotificationConfig(value: unknown): NotificationConfig {
  const response = object(value)
  if (!Array.isArray(response.settings)) throw new Error("提醒设置字段无效")
  return {
    bound: boolean(response.bound), backgroundAuthorized: boolean(response.backgroundAuthorized),
    // 兼容尚未返回投递状态的旧后端；存在的字段必须严格校验。
    backgroundSuspended: response.backgroundSuspended === undefined ? false : boolean(response.backgroundSuspended),
    lastCheckedAt: nullableText(response.lastCheckedAt), lastError: nullableText(response.lastError),
    settings: Array.from(response.settings, (value) => {
      const row = object(value)
      if (typeof row.credits !== "number" || !Number.isInteger(row.credits) || row.credits < 0) throw new Error("订阅次数字段无效")
      const templateId = nullableText(row.templateId)
      const subscriptionStatus = text(row.subscriptionStatus)
      const statusText = !templateId ? "模板待配置" : subscriptionStatus === "ban" ? "订阅已被封禁" :
        subscriptionStatus === "reject" ? "已拒绝订阅" : subscriptionStatus === "filter" ? "模板被微信过滤" :
        row.credits > 0 ? `可提醒 ${row.credits} 次` : "请订阅下一次提醒"
      const delivery = row.lastDelivery === undefined || row.lastDelivery === null ? null : object(row.lastDelivery)
      const deliveryLabels: Record<string, string> = {
        sending: "发送尝试已登记，尚无确认结果；不会自动重发",
        sent: "微信接口已接受；手机收件需实际核对",
        failed: "微信接口拒绝发送", unknown: "发送结果未知；请核对微信消息，不会自动重发",
        unconfigured: "模板未配置", no_subscription: "发送时订阅次数耗尽",
        unsupported: "该事件不支持微信投递", invalid: "事件数据不满足模板要求"
      }
      const deliveryStatus = delivery ? text(delivery.status) : null
      if (deliveryStatus !== null && !Object.prototype.hasOwnProperty.call(deliveryLabels, deliveryStatus)) throw new Error("投递状态无效")
      const deliveryText = delivery && deliveryStatus !== null
        ? `${text(delivery.attemptedAt)}：${deliveryLabels[deliveryStatus]}` : null
      return { type: notificationType(row.type), label: text(row.label), templateId, enabled: boolean(row.enabled),
        credits: row.credits, subscriptionStatus, lastError: nullableText(row.lastError), statusText,
        deliveryText, deliveryError: delivery ? nullableText(delivery.error) : null }
    })
  }
}

export function reminderDestination(type: NotificationType): { url: string; tab: boolean } {
  const routes: Record<NotificationType, string> = {
    exam_reminder: "exams", grade_update: "grades", course_reminder: "schedule", attendance_update: "attendance", ecard_reminder: "ecard"
  }
  return { url: `/pages/${routes[type]}/index`, tab: type === "course_reminder" }
}

export function loadNotificationConfig(): Promise<NotificationConfig> {
  return get("/mini/notifications/config", parseNotificationConfig)
}

/** 必须直接在点击事件调用，微信弹窗前不能先等待网络请求。 */
export function subscribeNext(setting: NotificationSetting): Promise<NotificationConfig> {
  if (!setting.templateId) return Promise.reject(new Error("订阅模板待配置"))
  const templateId = setting.templateId
  const requestId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`
  return new Promise((resolve, reject) => {
    wx.requestSubscribeMessage({
      tmplIds: [templateId],
      success: async (result) => {
        try {
          const status = result[templateId]
          if (!["accept", "reject", "ban", "filter"].includes(status)) throw new Error("微信未返回有效的订阅结果")
          const code = await requestWechatCode()
          resolve(await post("/mini/notifications/subscription", { type: setting.type, templateId, requestId, result: status, code }, parseNotificationConfig))
        } catch (error) { reject(error) }
      },
      fail: (error) => reject(new Error(`微信订阅失败：${error.errMsg}`))
    })
  })
}
