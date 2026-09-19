/**
 * 接口地址解析。
 *
 * 小程序若不区分「开发/体验版」与「正式版」的接口地址，测试流量会直接打到生产库。
 * 这里按 `envVersion` 分流：开发者工具（develop）与体验版（trial）走测试 API，
 * 正式版（release）走生产 API。
 *
 * 测试环境与生产环境共用同一台腾讯云主机，但使用独立子域名与独立数据库。
 * 正式域名与测试域名都必须配置到微信公众平台的 request 合法域名中。
 */

/** 生产 API：正式版小程序唯一允许访问的地址。 */
export const PRODUCTION_API_BASE_URL = "https://onegzus.onrein.top/api"

/** 测试 API：仅 develop / trial 使用，独立库、DEBUG=true，绝不接入真实学生数据。 */
export const TEST_API_BASE_URL = "https://test-api.onrein.top/api"

type EnvVersion = "develop" | "trial" | "release"

/** 读取当前运行版本；基础库异常或非小程序环境时按正式版处理。 */
export function currentEnvVersion(): EnvVersion {
  try {
    const envVersion = wx.getAccountInfoSync().miniProgram.envVersion
    if (envVersion === "develop" || envVersion === "trial") return envVersion
  } catch {
    // 基础库过低或非小程序环境：安全降级到正式版。
  }
  return "release"
}

/** 按运行版本选择接口地址；只有 release 才允许命中生产。 */
export function resolveApiBaseUrl(envVersion: EnvVersion = currentEnvVersion()): string {
  return envVersion === "release" ? PRODUCTION_API_BASE_URL : TEST_API_BASE_URL
}

export const apiBaseUrl = resolveApiBaseUrl()
