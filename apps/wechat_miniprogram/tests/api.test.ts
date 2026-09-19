import { strict as assert } from "node:assert"
import { test } from "node:test"

import { get, post, put, remove, requireSession } from "../utils/api"
import { PRODUCTION_API_BASE_URL, TEST_API_BASE_URL } from "../utils/config"

interface CapturedRequest {
  url: string
  method: string
  data: unknown
  header: Record<string, string>
}

interface WxMockOptions {
  envVersion?: string
  sessionId?: string
  response?: { statusCode: number; data: unknown }
  failWith?: string
}

interface WxMock {
  store: Map<string, unknown>
  removed: string[]
  reLaunchUrls: string[]
  captured: CapturedRequest[]
}

type GlobalWithWx = typeof globalThis & { wx?: unknown }

function installWxMock(options: WxMockOptions = {}): WxMock {
  const store = new Map<string, unknown>()
  if (options.sessionId !== undefined) store.set("auth.sessionId", options.sessionId)

  const removed: string[] = []
  const reLaunchUrls: string[] = []
  const captured: CapturedRequest[] = []

  const wxMock = {
    getAccountInfoSync: () => ({ miniProgram: { envVersion: options.envVersion ?? "develop" } }),
    getStorageSync: (key: string) => store.get(key) ?? "",
    setStorageSync: (key: string, value: unknown) => {
      store.set(key, value)
    },
    removeStorageSync: (key: string) => {
      store.delete(key)
      removed.push(key)
    },
    reLaunch: (arg: { url: string }) => {
      reLaunchUrls.push(arg.url)
    },
    request: (arg: {
      url: string
      method: string
      data: unknown
      header: Record<string, string>
      success: (response: { statusCode: number; data: unknown }) => void
      fail: (error: { errMsg: string }) => void
    }) => {
      captured.push({ url: arg.url, method: arg.method, data: arg.data, header: arg.header })
      if (options.failWith !== undefined) {
        arg.fail({ errMsg: options.failWith })
        return
      }
      arg.success(options.response ?? { statusCode: 200, data: {} })
    }
  }

  ;(globalThis as GlobalWithWx).wx = wxMock
  return { store, removed, reLaunchUrls, captured }
}

const identity = (value: unknown): unknown => value

test("GET 在 develop 下命中测试域名并携带会话与平台头", async () => {
  const mock = installWxMock({ envVersion: "develop", sessionId: "mini-session" })

  await get("/academic/me", identity)

  assert.equal(mock.captured.length, 1)
  assert.equal(mock.captured[0].url, `${TEST_API_BASE_URL}/academic/me`)
  assert.equal(mock.captured[0].method, "GET")
  assert.equal(mock.captured[0].header["X-Session-Id"], "mini-session")
  assert.equal(mock.captured[0].header["X-Client-Platform"], "wechat-mini-program")
  assert.equal(mock.captured[0].header["Content-Type"], "application/json")
})

test("GET 在 release 下命中生产域名", async () => {
  const mock = installWxMock({ envVersion: "release", sessionId: "mini-session" })

  await get("/academic/me", identity)

  assert.equal(mock.captured[0].url, `${PRODUCTION_API_BASE_URL}/academic/me`)
})

test("POST 传递方法与请求体", async () => {
  const mock = installWxMock({ envVersion: "develop" })

  await post("/mini/auth/login", { account: "20260001", password: "secret" }, identity)

  assert.equal(mock.captured[0].method, "POST")
  assert.deepEqual(mock.captured[0].data, { account: "20260001", password: "secret" })
})

test("PUT 与 DELETE 传递正确方法", async () => {
  const mock = installWxMock()

  await put("/settings/academic-period", { year: 2026, term: 1 }, identity)
  await remove("/mini/auth/wechat-binding", identity)

  assert.equal(mock.captured[0].method, "PUT")
  assert.deepEqual(mock.captured[0].data, { year: 2026, term: 1 })
  assert.equal(mock.captured[1].method, "DELETE")
})

test("结构化服务端错误保留业务 code", async () => {
  installWxMock({
    response: {
      statusCode: 409,
      data: { detail: { code: "wechat_not_bound", message: "请先绑定" } }
    }
  })

  await assert.rejects(
    post("/mini/auth/wechat-login", { code: "one-time-code" }, identity),
    (error: unknown) => {
      return error instanceof Error &&
        error.message === "请先绑定" &&
        (error as { code?: string }).code === "wechat_not_bound"
    }
  )
})

test("成功响应交给解析器并返回其结果", async () => {
  installWxMock({ response: { statusCode: 200, data: { status: "ok", value: 7 } } })

  const parsed = await get("/academic/me", (value) => (value as { value: number }).value)

  assert.equal(parsed, 7)
})

test("携带会话的 401 清除本地会话并提示重新登录", async () => {
  const mock = installWxMock({
    sessionId: "expired-session",
    response: { statusCode: 401, data: {} }
  })

  await assert.rejects(get("/academic/me", identity), /登录已失效，请重新登录/)

  assert.deepEqual(mock.removed, ["auth.sessionId"])
  assert.equal(mock.store.has("auth.sessionId"), false)
})

test("携带会话的 401 优先透传服务端下线文案", async () => {
  const mock = installWxMock({
    sessionId: "expired-session",
    response: { statusCode: 401, data: { detail: "当前设备已被管理员下线，请重新验证登录" } }
  })

  await assert.rejects(get("/academic/me", identity), /当前设备已被管理员下线，请重新验证登录/)

  assert.deepEqual(mock.removed, ["auth.sessionId"])
})

test("登录接口 401 提示账号或密码错误且不清空本地状态", async () => {
  const mock = installWxMock({ response: { statusCode: 401, data: {} } })

  await assert.rejects(
    post("/mini/auth/login", { account: "20260001", password: "wrong" }, identity),
    /账号或密码错误/
  )

  assert.deepEqual(mock.removed, [])
})

test("登录接口 401 透传服务端凭据错误文案", async () => {
  const mock = installWxMock({
    response: { statusCode: 401, data: { detail: "演示账号或密码错误" } }
  })

  await assert.rejects(
    post("/mini/auth/login", { account: "demo", password: "wrong" }, identity),
    /演示账号或密码错误/
  )

  assert.deepEqual(mock.removed, [])
})

test("403 使用服务端 detail 文案且不清除会话", async () => {
  const mock = installWxMock({
    sessionId: "mini-session",
    response: { statusCode: 403, data: { detail: "演示账号仅支持查看" } }
  })

  await assert.rejects(get("/ecard/summary", identity), /演示账号仅支持查看/)

  assert.deepEqual(mock.removed, [])
  assert.equal(mock.store.get("auth.sessionId"), "mini-session")
})

test("缺少 detail 时使用状态码兜底文案", async () => {
  installWxMock({ response: { statusCode: 500, data: {} } })

  await assert.rejects(get("/academic/schedule", identity), /请求失败（500）/)
})

test("响应格式无效时向上抛出解析错误", async () => {
  installWxMock({ response: { statusCode: 200, data: { unexpected: true } } })

  await assert.rejects(
    get("/academic/me", () => {
      throw new Error("个人信息响应格式无效")
    }),
    /个人信息响应格式无效/
  )
})

test("网络失败时使用 errMsg", async () => {
  installWxMock({ failWith: "request:fail timeout" })

  await assert.rejects(get("/academic/me", identity), /request:fail timeout/)
})

test("请求合法域名未配置时给出后台配置指引", async () => {
  installWxMock({ failWith: "request:fail url not in domain list" })

  await assert.rejects(get("/academic/me", identity), /微信未配置请求合法域名.*test-api\.onrein\.top/)
})

test("无 errMsg 的网络失败给出兜底文案", async () => {
  installWxMock({ failWith: "" })

  await assert.rejects(get("/academic/me", identity), /网络连接失败/)
})

test("requireSession 在有会话时放行且不跳转", () => {
  const mock = installWxMock({ sessionId: "mini-session" })

  assert.equal(requireSession(), true)
  assert.deepEqual(mock.reLaunchUrls, [])
})

test("requireSession 在无会话时跳转登录页", () => {
  const mock = installWxMock()

  assert.equal(requireSession(), false)
  assert.deepEqual(mock.reLaunchUrls, ["/pages/login/index"])
})
