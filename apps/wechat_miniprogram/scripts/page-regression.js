#!/usr/bin/env node
/**
 * 微信开发者工具页面回归（miniprogram-automator）。
 *
 * 覆盖：空输入校验、错误密码、登录成功、首页/课表/成绩/考勤/考试/通知/生活缴费/个人信息
 * 加载、401 清理本地会话、下拉刷新、退出登录、网络错误态、无会话跳转登录页。
 *
 * 设计取舍：
 *   - 全程 mock `wx.request`，因此不需要测试环境在线，也不需要演示账号密码；
 *     真实接口链路由后端集成测试覆盖，真机验收再打真实测试域名。
 *   - 失败时把截图与控制台日志写到 test-artifacts/，且写入前统一脱敏。
 *
 * 前置条件（缺一不可）：
 *   1. 已安装微信开发者工具；
 *   2. 开发者工具「设置 → 安全设置」已开启服务端口；
 *   3. 开发者工具已登录（未登录时 automator.launch 会失败）。
 */

const fs = require("node:fs")
const path = require("node:path")
const automator = require("miniprogram-automator")

const { resolveCliPath, projectRoot, artifactDir, startAutomation, autoPort } = require("./devtools-cli")
const { buildScenario, requestMock, serverErrorMock, ECARD_NOT_BOUND } = require("./automation-fixtures")

const { version: LEGAL_VERSION } = require("../utils/generated/version.json")

const PROJECT = projectRoot()
/**
 * 失败现场必须写在项目目录**之外**：开发者工具会监听项目目录，往项目里写截图/日志
 * 会触发重新编译，AppService 一重载注入的 `wx.request` mock 就失效，真实请求随即
 * 撞上域名白名单，后续用例会成片假失败。可用 WECHAT_TEST_ARTIFACT_DIR 覆盖。
 */
const ARTIFACT_DIR = artifactDir()
const PAGE_TIMEOUT_MS = 20000
const POLL_INTERVAL_MS = 150

let miniProgram = null
const consoleBuffer = []
const results = []

// ─── 输出与脱敏 ──────────────────────────────────────────────────────

/** 日志绝不允许出现密码、Cookie 或会话 ID。 */
function sanitize(text) {
  return String(text === null || text === undefined ? "" : text)
    .replace(/automation-session-id/g, "<session-id>")
    .replace(/automation-password/g, "<password>")
    .replace(/(X-Session-Id"?\s*[:=]\s*"?)[^"',\s}]+/gi, "$1<session-id>")
    .replace(/("?(?:password|sessionId|session_id|credentialToken|authToken)"?\s*[:=]\s*"?)[^"',\s}]+/gi, "$1<redacted>")
}

function log(message) {
  process.stdout.write(sanitize(message) + "\n")
}

// ─── 断言 ────────────────────────────────────────────────────────────

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}：期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`)
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// ─── 等待工具 ────────────────────────────────────────────────────────

async function waitFor(probe, description, timeoutMs = PAGE_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs
  let last
  while (Date.now() < deadline) {
    last = await probe()
    if (last) return last
    await sleep(POLL_INTERVAL_MS)
  }
  throw new Error(`等待超时（${timeoutMs}ms）：${description}`)
}

/**
 * automator 返回的 `page.path` 不带前导斜杠（形如 `pages/home/index`），
 * 而代码里写的是 `/pages/home/index`；统一去掉斜杠后再比较。
 */
function normalizePath(value) {
  return String(value || "").replace(/^\/+/, "").replace(/\/+$/, "")
}

function pathMatches(actual, expected) {
  const want = normalizePath(expected)
  return want.length > 0 && normalizePath(actual).indexOf(want) !== -1
}

/** 页面栈路径快照，用于失败时说明「到底停在哪一页」。 */
async function describeStack() {
  try {
    const stack = await miniProgram.pageStack()
    return stack.map((item) => item.path).filter(Boolean)
  } catch {
    return []
  }
}

async function waitForPage(pathFragment) {
  const deadline = Date.now() + PAGE_TIMEOUT_MS
  let lastPath = ""
  while (Date.now() < deadline) {
    const page = await miniProgram.currentPage()
    lastPath = page ? page.path : ""
    if (pathMatches(lastPath, pathFragment)) return page
    await sleep(POLL_INTERVAL_MS)
  }
  const stack = await describeStack()
  throw new Error(
    `等待页面 ${pathFragment} 超时（当前页面：${lastPath || "未知"}；页面栈：${stack.join(" > ") || "空"}）`
  )
}

async function waitForSelector(page, selector) {
  return waitFor(async () => (await page.$(selector)) || null, `元素 ${selector}`)
}

async function waitForSelectorCount(page, selector, count) {
  return waitFor(async () => {
    const elements = await page.$$(selector)
    return elements.length === count ? elements : null
  }, `元素 ${selector} 数量为 ${count}`)
}

// ─── 小程序状态操作 ──────────────────────────────────────────────────

async function clearStorage() {
  await miniProgram.evaluate(() => {
    wx.clearStorageSync()
  })
}

async function readSessionState() {
  return miniProgram.evaluate(() => ({
    sessionId: wx.getStorageSync("auth.sessionId"),
    studentName: wx.getStorageSync("auth.studentName"),
    studentId: wx.getStorageSync("auth.studentId")
  }))
}

async function seedSession() {
  await miniProgram.evaluate((version) => {
    wx.setStorageSync("legal.acceptedVersion", version)
    wx.setStorageSync("auth.sessionId", "automation-session-id")
    wx.setStorageSync("auth.studentName", "演示同学")
    wx.setStorageSync("auth.studentId", "DEMO-2026-001")
  }, LEGAL_VERSION)
}

async function mockScenario(overrides) {
  await miniProgram.mockWxMethod("request", requestMock, buildScenario(overrides))
}

/**
 * 预检：确认 wx.request 的 mock 真的生效。
 *
 * 开发者工具在重新编译后会重载 AppService，注入的 mock 可能失效；此时真实请求会
 * 撞上域名白名单（`request:fail url not in domain list`），表现成一堆看不懂的失败。
 * 这里先自证一次，避免把工具状态问题误判成页面缺陷。
 */
async function verifyMockWorks() {
  await miniProgram.mockWxMethod("request", requestMock, {
    "GET /__selftest__": { statusCode: 200, data: { ok: true } }
  })
  const result = await miniProgram.evaluate(() => {
    return new Promise((resolve) => {
      wx.request({
        url: "https://selftest.invalid/api/__selftest__",
        method: "GET",
        success: (res) => resolve({ data: res && res.data }),
        fail: (err) => resolve({ fail: (err && err.errMsg) || "unknown" })
      })
    })
  })
  await miniProgram.restoreWxMethod("request")
  assert(
    result && result.data && result.data.ok === true,
    `wx.request mock 未生效，实际：${JSON.stringify(result)}`
  )
}

async function agreeLegal(page) {
  await (await waitForSelector(page, "#login-agreement")).trigger("change", { value: ["agree"] })
}

async function fillLoginForm(page, account, password) {
  await agreeLegal(page)
  await (await waitForSelector(page, "#login-account")).input(account)
  await (await waitForSelector(page, "#login-password")).input(password)
  await (await waitForSelector(page, "#login-submit")).tap()
}

// ─── 用例执行与失败现场 ──────────────────────────────────────────────

async function captureArtifacts(name) {
  try {
    fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
    const safe = name.replace(/[^\w\u4e00-\u9fa5-]/g, "_").slice(0, 60)
    if (miniProgram) {
      await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, `${safe}.png`) })
    }
    fs.writeFileSync(
      path.join(ARTIFACT_DIR, `${safe}.log`),
      sanitize(consoleBuffer.join("\n")),
      "utf8"
    )
    log(`    ↳ 现场已保存到 ${path.join(ARTIFACT_DIR, safe)}.{png,log}`)
  } catch (error) {
    log(`    ↳ 采集失败现场失败：${error && error.message}`)
  }
}

/** 自动化连接是否仍然可用；掉线后继续跑只会刷出一堆级联超时。 */
async function isAlive() {
  const timeoutMarker = "__PROBE_TIMEOUT__"
  try {
    const raced = await Promise.race([
      miniProgram.currentPage().then(() => "ok"),
      sleep(5000).then(() => timeoutMarker)
    ])
    return raced !== timeoutMarker
  } catch {
    return false
  }
}

async function check(name, fn) {
  try {
    await fn()
    results.push({ name, ok: true })
    log(`✔ ${name}`)
    return true
  } catch (error) {
    const detail = error && error.message ? error.message : String(error)
    results.push({ name, ok: false, detail })
    log(`✖ ${name}`)
    log(`    ${detail}`)
    await captureArtifacts(name)
    if (!(await isAlive())) {
      log("")
      log("⚠ 自动化连接已断开，停止后续用例（结果不完整）。")
      return false
    }
    return true
  }
}

// ─── 用例 ────────────────────────────────────────────────────────────

let aborted = false

/**
 * 预热：刚打开项目时首个页面的 meta 可能还没就绪，
 * 直接操作会报 `Cannot destructure property 'rawPath' of getPageMetaByWebviewId(...)`。
 */
async function warmUp() {
  let lastError
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      const page = await miniProgram.reLaunch("/pages/login/index")
      await waitForSelector(page, "#login-submit")
      return true
    } catch (error) {
      lastError = error
      await sleep(1000)
    }
  }
  log(`⚠ 预热失败（继续执行，首个用例可能受影响）：${lastError && lastError.message}`)
  return false
}

/** 跑一个用例；一旦自动化连接断开就停止后续用例。 */
async function runCase(name, fn) {
  if (aborted) return
  // 每个用例开始前重建基线 mock：AppService 若在用例之间重载过，mock 会丢失。
  try {
    await mockScenario()
  } catch (error) {
    log(`⚠ 重建 mock 失败：${error && error.message}`)
  }
  if (!(await check(name, fn))) aborted = true
}

async function runCases() {
  await runCase("未同意协议时两种登录均被阻止且可阅读完整协议", async () => {
    await clearStorage()
    await miniProgram.mockWxMethod("login", { code: "must-not-use-code" })
    await mockScenario({ "POST /mini/auth/login": { statusCode: 599, data: {} }, "POST /mini/auth/wechat-login": { statusCode: 599, data: {} } })
    let page = await miniProgram.reLaunch("/pages/login/index")
    await (await waitForSelector(page, "#login-submit")).tap()
    assert((await (await waitForSelector(page, "#login-error")).text()).includes("请先阅读并同意"), "学校登录应要求同意协议")
    await (await waitForSelector(page, "#login-wechat")).tap()
    assert((await (await waitForSelector(page, "#login-error")).text()).includes("请先阅读并同意"), "微信登录应要求同意协议")
    await (await waitForSelector(page, "#login-terms")).tap()
    page = await waitForPage("/pages/legal/index")
    await waitForSelector(page, "#legal-content")
    await miniProgram.navigateBack()
    page = await waitForPage("/pages/login/index")
    await (await waitForSelector(page, "#login-privacy")).tap()
    page = await waitForPage("/pages/legal/index")
    await waitForSelector(page, "#legal-content")
    assertEqual((await readSessionState()).sessionId, "", "阅读协议不创建会话")
  })

  await runCase("已有会话必须确认新版协议，确认后复用会话", async () => {
    await clearStorage()
    await seedSession()
    await miniProgram.evaluate(() => wx.setStorageSync("legal.acceptedVersion", "previous-version"))
    await mockScenario({ "POST /mini/auth/login": { statusCode: 599, data: {} } })
    const page = await miniProgram.reLaunch("/pages/login/index")
    await (await waitForSelector(page, "#login-continue")).tap()
    assert((await (await waitForSelector(page, "#login-error")).text()).includes("请先阅读并同意"), "旧会话不能绕过新版协议")
    await agreeLegal(page)
    await (await waitForSelector(page, "#login-continue")).tap()
    await waitForPage("/pages/home/index")
    assertEqual((await readSessionState()).sessionId, "automation-session-id", "应复用已有会话")
  })

  await runCase("教务通知显示正文并提供原文链接复制", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()
    const list = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(list, "#notice-0")).tap()
    const detail = await waitForPage("/pages/notice-detail/index")
    assertEqual(await (await waitForSelector(detail, "#notice-detail-content")).text(), "第一段 & 说明\n第二段", "通知正文")
    await miniProgram.mockWxMethod("setClipboardData", { errMsg: "setClipboardData:ok" })
    await (await waitForSelector(detail, "#notice-detail-copy")).tap()
    await miniProgram.restoreWxMethod("setClipboardData")
  })

  await runCase("非教务来源展示摘要且不调用教务详情接口", async () => {
    await clearStorage()
    await seedSession()
    for (const source of ["ehall", "wechat", "admin"]) {
      await mockScenario({
        "GET /notices": { statusCode: 200, data: [{ category: "通知", title: "来源通知", source, summary: "已有说明", url: "https://example.com/original" }] },
        "GET /notices/detail": { statusCode: 599, data: { detail: "不应请求教务详情" } }
      })
      const list = await miniProgram.reLaunch("/pages/notices/index")
      await (await waitForSelector(list, "#notice-0")).tap()
      const detail = await waitForPage("/pages/notice-detail/index")
      assertEqual(await (await waitForSelector(detail, "#notice-detail-content")).text(), "已有说明", "摘要或发布说明")
      assert(!(await detail.$("#notice-detail-error")), "非教务通知不应加载教务详情")
    }
  })

  await runCase("详情加载失败可重试且不把摘要当作正文", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({ "GET /notices/detail": { statusCode: 503, data: { detail: "详情暂不可用" } } })
    const list = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(list, "#notice-0")).tap()
    const detail = await waitForPage("/pages/notice-detail/index")
    await waitForSelector(detail, "#notice-detail-error")
    assert(!(await detail.$("#notice-detail-content")), "失败时不应展示摘要充当正文")
    await mockScenario()
    await (await waitForSelector(detail, "#notice-detail-retry")).tap()
    await waitForSelector(detail, "#notice-detail-content")
  })

  await runCase("空正文、缺原文地址及封面失败均有明确反馈", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({ "GET /notices/detail": { statusCode: 200, data: { title: "空通知", date: null, url: "https://jwxt.gzus.edu.cn/notice/1", contentHtml: "<p> </p>" } } })
    let list = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(list, "#notice-0")).tap()
    let detail = await waitForPage("/pages/notice-detail/index")
    await waitForSelector(detail, "#notice-detail-empty")
    await mockScenario({ "GET /notices": { statusCode: 200, data: [{ category: "校历", title: "校历", source: "admin", summary: null, url: null, coverUrl: "/admin/notices/1/image" }] } })
    list = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(list, "#notice-0")).tap()
    detail = await waitForPage("/pages/notice-detail/index")
    await waitForSelector(detail, "#notice-detail-empty")
    assert(!(await detail.$("#notice-detail-copy")), "缺地址时不应出现复制按钮")
    await detail.callMethod("onCoverError")
    await waitForSelector(detail, "#notice-detail-cover-error")
  })

  await runCase("详情会话失效时回到登录页", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({ "GET /notices/detail": { statusCode: 401, data: { detail: "登录已过期，请重新登录" } } })
    const list = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(list, "#notice-0")).tap()
    await waitForPage("/pages/login/index")
    assertEqual((await readSessionState()).sessionId, "", "失效会话应清除")
  })

  await runCase("空输入时提示学号密码必填且不写入会话", async () => {
    await clearStorage()
    await mockScenario()
    const page = await miniProgram.reLaunch("/pages/login/index")
    await agreeLegal(page)
    await (await waitForSelector(page, "#login-submit")).tap()

    const error = await waitForSelector(page, "#login-error")
    assertEqual(await error.text(), "请输入学号和密码", "空输入错误提示")

    const state = await readSessionState()
    assertEqual(state.sessionId, "", "空输入不应写入会话")
  })

  await runCase("密码错误时透传服务端凭据文案且不写入会话", async () => {
    await clearStorage()
    await mockScenario({
      "POST /mini/auth/login": { statusCode: 401, data: { detail: "演示账号或密码错误" } }
    })
    const page = await miniProgram.reLaunch("/pages/login/index")
    await fillLoginForm(page, "DEMO-2026-001", "automation-password")

    const error = await waitForSelector(page, "#login-error")
    const text = await error.text()
    assert(
      text.indexOf("演示账号或密码错误") !== -1,
      `登录页应展示服务端凭据错误文案，实际：${text}`
    )

    const state = await readSessionState()
    assertEqual(state.sessionId, "", "密码错误不应写入会话")
  })

  await runCase("演示账号登录成功后进入首页并写入会话", async () => {
    await clearStorage()
    await mockScenario()
    await miniProgram.mockWxMethod("showModal", { confirm: false, cancel: true })
    const page = await miniProgram.reLaunch("/pages/login/index")
    await fillLoginForm(page, "DEMO-2026-001", "automation-password")

    const home = await waitForPage("/pages/home/index")
    const greeting = await waitForSelector(home, "#home-greeting")
    assert(
      (await greeting.text()).indexOf("演示同学") !== -1,
      "首页问候语应展示学生姓名"
    )

    const state = await readSessionState()
    assertEqual(state.sessionId, "automation-session-id", "登录后应写入会话")
    assertEqual(state.studentName, "演示同学", "登录后应写入学生姓名")
    assertEqual(state.studentId, "DEMO-2026-001", "登录后应写入学号")
  })

  await runCase("认证成功后学期同步失败可复用会话重试且清空密码", async () => {
    await clearStorage()
    await mockScenario({ "GET /settings/academic-period": { statusCode: 503, data: { detail: "学期服务暂不可用" } } })
    const page = await miniProgram.reLaunch("/pages/login/index")
    await fillLoginForm(page, "DEMO-2026-001", "automation-password")
    assertEqual(await (await waitForSelector(page, "#login-error")).text(), "学期服务暂不可用", "同步错误应明确显示")
    await waitForSelector(page, "#login-continue")
    assertEqual(await page.data("password"), "", "认证成功后应清空页面密码")
    await mockScenario({ "POST /mini/auth/login": { statusCode: 599, data: { detail: "不应再次认证" } } })
    await (await waitForSelector(page, "#login-continue")).tap()
    await waitForPage("/pages/home/index")
  })

  await runCase("考勤汇总在手机宽度呈三列两行", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()
    const page = await miniProgram.reLaunch("/pages/attendance/index")
    const summary = await waitForSelector(page, "#attendance-summary")
    const metrics = await summary.$$(".metric")
    assertEqual(metrics.length, 6, "汇总项数量")
    const positions = await Promise.all(metrics.map((element) => element.offset()))
    assert(Math.abs(positions[0].top - positions[1].top) < 2 && Math.abs(positions[1].top - positions[2].top) < 2, "前三项应同一行")
    assert(positions[3].top > positions[0].top && Math.abs(positions[3].top - positions[5].top) < 2, "后三项应位于第二行")
    assert(positions[1].left > positions[0].left && positions[2].left > positions[1].left, "每行应为三列")
  })

  await runCase("成绩显示及格边界、文字成绩、未知和待公布", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({ "GET /grades": { statusCode: 200, data: [
      { courseName: "59分", score: "59", gradePassed: false }, { courseName: "60分", score: "60", gradePassed: true },
      { courseName: "教务结论", score: "90", gradePassed: false }, { courseName: "文字成绩", score: "合格", gradePassed: true },
      { courseName: "未知", score: "优秀", gradePassed: null }, { courseName: "待公布", score: "", gradePassed: null }
    ] } })
    const page = await miniProgram.reLaunch("/pages/grades/index")
    for (const [index, expected] of ["不及格", "及格", "不及格", "及格", "无法判断", "待公布"].entries()) {
      assertEqual(await (await waitForSelector(page, `#grade-status-${index}`)).text(), expected, "成绩状态")
    }
  })

  await runCase("个人提醒已读后跳转，成绩模板待配置可见", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /notifications/events": { statusCode: 200, data: { events: [{ id: "grade-test", type: "grade_update", title: "成绩更新", body: "数学：合格", createdAt: "2026-10-04", readAt: null }] } },
      "POST /notifications/events/grade-test/read": { statusCode: 200, data: { status: "ok" } }
    })
    const page = await miniProgram.reLaunch("/pages/notices/index")
    await (await waitForSelector(page, "#notices-personal-tab")).tap()
    await (await waitForSelector(page, "#notification-settings-toggle")).tap()
    assertEqual(await (await waitForSelector(page, "#notification-status-grade_update")).text(), "模板待配置", "成绩模板状态")
    assert((await (await waitForSelector(page, "#reminder-0")).text()).includes("未读"), "个人提醒应显示未读")
    await (await waitForSelector(page, "#reminder-0")).tap()
    await waitForPage("/pages/grades/index")
  })

  await runCase("生活缴费跳转使用正确 AppID 且失败明确可见", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()
    const page = await miniProgram.reLaunch("/pages/ecard/index")
    await miniProgram.mockWxMethod("navigateToMiniProgram", (options) => {
      wx.setStorageSync("automation.lastMiniAppId", options.appId)
      return { errMsg: "navigateToMiniProgram:ok" }
    })
    try {
      await (await waitForSelector(page, "#ecard-campus-card")).tap()
      await waitFor(async () => (await miniProgram.evaluate(() => wx.getStorageSync("automation.lastMiniAppId"))) === "wx777061f467655121", "校园卡 AppID")
      await (await waitForSelector(page, "#ecard-hot-water-recharge")).tap()
      await waitFor(async () => (await miniProgram.evaluate(() => wx.getStorageSync("automation.lastMiniAppId"))) === "wxc67cd96204f3d163", "热水 AppID")
      await miniProgram.mockWxMethod("navigateToMiniProgram", { errMsg: "navigateToMiniProgram:fail invalid appid" })
      await (await waitForSelector(page, "#ecard-campus-card")).tap()
      assert((await (await waitForSelector(page, "#ecard-error")).text()).includes("invalid appid"), "跳转失败应保留微信具体原因")
    } finally { await miniProgram.restoreWxMethod("navigateToMiniProgram") }
  })

  await runCase("已有会话恢复时过期会重新显示学校登录表单", async () => {
    await clearStorage()
    await seedSession()
    await miniProgram.evaluate(() => wx.setStorageSync("legal.acceptedVersion", "previous-version"))
    await mockScenario({ "GET /settings/academic-period": { statusCode: 401, data: { detail: "学校会话已过期" } } })
    const page = await miniProgram.reLaunch("/pages/login/index")
    await agreeLegal(page)
    await (await waitForSelector(page, "#login-continue")).tap()
    await waitForSelector(page, "#login-account")
    await waitForSelector(page, "#login-submit")
    assertEqual(await (await waitForSelector(page, "#login-error")).text(), "学校会话已过期", "会话错误文案")
    assertEqual((await readSessionState()).sessionId, "", "过期会话应清除")
  })

  await runCase("首页展示冷/热/电余额模块", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    const home = await miniProgram.reLaunch("/pages/home/index")
    await waitForSelector(home, "#home-ecard")

    const power = await (await waitForSelector(home, "#home-ecard-power")).text()
    assert(power.indexOf("68.4") !== -1, `电费应显示 68.4，实际：${power}`)
    const cold = await (await waitForSelector(home, "#home-ecard-cold-water")).text()
    assert(cold.indexOf("12.5") !== -1, `冷水应显示 12.5，实际：${cold}`)
    const hot = await (await waitForSelector(home, "#home-ecard-hot-water")).text()
    assert(hot.indexOf("30.2") !== -1, `热水应显示 30.2，实际：${hot}`)
  })

  await runCase("首页未绑定宿舍时引导去生活缴费绑定", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /ecard/summary": { statusCode: 200, data: ECARD_NOT_BOUND }
    })

    const home = await miniProgram.reLaunch("/pages/home/index")
    const notice = await waitForSelector(home, "#home-ecard-not-bound")
    const text = await notice.text()
    assert(text.indexOf("生活缴费") !== -1, `应引导去生活缴费绑定，实际：${text}`)
  })

  await runCase("水电接口失败不影响首页其它模块", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /ecard/summary": { statusCode: 500, data: { detail: "一卡通服务不可用" } }
    })

    const home = await miniProgram.reLaunch("/pages/home/index")
    await waitForSelector(home, "#home-quick-grid")

    // 核心模块必须照常渲染
    await waitForSelectorCount(home, ".home-course-row", 3)
    const pageError = await home.$("#home-error")
    assert(!pageError, "水电失败不应把整个首页打成错误页")

    // 失败只体现在水电卡片内部
    const ecardError = await waitForSelector(home, "#home-ecard-error")
    const text = await ecardError.text()
    assert(text.indexOf("一卡通服务不可用") !== -1, `水电卡片应提示失败原因，实际：${text}`)
  })

  await runCase("首页加载近期课程与考试提醒且无错误态", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    await miniProgram.reLaunch("/pages/home/index")
    const home = await waitForPage("/pages/home/index")
    await waitForSelector(home, "#home-quick-grid")

    const courses = await waitForSelectorCount(home, ".home-course-row", 3)
    assert(courses.length === 3, "首页应展示 3 条近期课程")
    const firstCourseText = await courses[0].text()
    assert(firstCourseText.indexOf("09:00-10:20") !== -1, `近期课程应展示上课时间，实际：${firstCourseText}`)

    const exams = await waitForSelectorCount(home, ".home-exam-row", 2)
    assert(exams.length === 2, "首页应展示 2 条考试提醒")

    const error = await home.$("#home-error")
    assert(!error, "首页不应出现错误态")
  })

  await runCase("课表、成绩、考勤、考试、通知、生活缴费、个人信息均完成加载", async () => {
    const targets = [
      { path: "/pages/schedule/index", items: ".course-block", count: 3, error: "#schedule-error", label: "课表" },
      { path: "/pages/grades/index", items: ".grade-card", count: 2, error: "#grades-error", label: "成绩" },
      { path: "/pages/attendance/index", items: ".attendance-card", count: 2, error: "#attendance-error", label: "考勤" },
      { path: "/pages/exams/index", items: ".exam-card", count: 2, error: "#exams-error", label: "考试" },
      { path: "/pages/notices/index", items: ".notice-card", count: 2, error: "#notices-error", label: "通知" },
      { path: "/pages/ecard/index", items: "#ecard-summary", count: 1, error: "#ecard-error", label: "生活缴费" },
      { path: "/pages/profile/index", items: "#profile-info", count: 1, error: "#profile-error", label: "个人信息" }
    ]

    for (const target of targets) {
      const page = await miniProgram.reLaunch(target.path)
      await waitForPage(target.path)
      await waitForSelectorCount(page, target.items, target.count)

      const error = await page.$(target.error)
      assert(!error, `${target.label}页不应出现错误态`)
    }

    const profile = await miniProgram.reLaunch("/pages/profile/index")
    const name = await waitForSelector(profile, "#profile-name")
    assertEqual(await name.text(), "演示同学", "个人信息应展示姓名")
  })

  await runCase("接口返回 401 时清理本地会话", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /me": { statusCode: 401, data: {} },
      "GET /schedule": { statusCode: 401, data: {} },
      "GET /exams": { statusCode: 401, data: {} },
      "GET /grades": { statusCode: 401, data: {} },
      "GET /notices": { statusCode: 401, data: {} },
      "GET /ecard/summary": { statusCode: 401, data: {} }
    })

    const page = await miniProgram.reLaunch("/pages/profile/index")
    await waitForSelector(page, "#profile-error")

    const state = await readSessionState()
    assertEqual(state.sessionId, "", "401 后应清理本地会话")
  })

  await runCase("下拉刷新重新拉取数据", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    const page = await miniProgram.reLaunch("/pages/schedule/index")
    await waitForSelectorCount(page, ".course-block", 3)

    await mockScenario({
      "GET /schedule": {
        statusCode: 200,
        data: [
          {
            name: "编译原理",
            teacher: "赵老师",
            classroom: "D401",
            weekday: 4,
            startSection: 1,
            endSection: 2,
            weeks: "1-16"
          }
        ]
      }
    })
    await page.callMethod("onPullDownRefresh")

    const refreshed = await waitForSelectorCount(page, ".course-block", 1)
    const refreshedText = await refreshed[0].text()
    assert(
      refreshedText.indexOf("编译原理") !== -1,
      `下拉刷新应更新课表内容，实际：${refreshedText}`
    )
  })

  await runCase("退出登录清空本地会话并回到登录页", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    const page = await miniProgram.reLaunch("/pages/profile/index")
    await waitForSelector(page, "#profile-info")
    await (await waitForSelector(page, "#profile-logout")).tap()

    await waitForPage("/pages/login/index")

    const state = await readSessionState()
    assertEqual(state.sessionId, "", "退出后应清空会话")
    assertEqual(state.studentName, "", "退出后应清空学生姓名")
    assertEqual(state.studentId, "", "退出后应清空学号")
  })

  await runCase("未绑定时可在小程序内搜索并绑定宿舍", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /ecard/summary": { statusCode: 200, data: ECARD_NOT_BOUND },
      "GET /ecard/rooms": {
        statusCode: 200,
        data: [
          {
            id: "1|演示校区|A1|101",
            schoolArea: "演示校区",
            building: "A1",
            room: "101",
            displayName: "演示宿舍 A1-101"
          }
        ]
      },
      "POST /ecard/binding": {
        statusCode: 200,
        data: {
          status: "ok",
          roomDisplay: "演示宿舍 A1-101",
          powerText: "88.8 度",
          coldWaterText: "8.8 吨",
          hotWaterText: "18.80元",
          stale: false
        }
      }
    })

    const page = await miniProgram.reLaunch("/pages/ecard/index")
    await waitForSelector(page, "#ecard-not-bound")
    await (await waitForSelector(page, "#ecard-bind-open")).tap()

    await (await waitForSelector(page, "#ecard-room-keyword")).input("A1")
    await (await waitForSelector(page, "#ecard-room-search")).tap()
    await waitForSelector(page, "#ecard-room-bind-0")
    await (await waitForSelector(page, "#ecard-room-bind-0")).tap()

    const summary = await waitForSelector(page, "#ecard-summary")
    const text = await summary.text()
    assert(text.indexOf("演示宿舍 A1-101") !== -1, `绑定后应展示宿舍名，实际：${text}`)
    assert(text.indexOf("88.8") !== -1, `绑定后应展示余额，实际：${text}`)

    const stillNotBound = await page.$("#ecard-not-bound")
    assert(!stillNotBound, "绑定成功后不应再显示未绑定提示")
  })

  await runCase("已绑定时提供重新绑定入口", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    const page = await miniProgram.reLaunch("/pages/ecard/index")
    await waitForSelector(page, "#ecard-summary")
    await (await waitForSelector(page, "#ecard-history-toggle")).tap()
    await waitForSelector(page, "#ecard-history-content")
    await waitForSelector(page, ".history-row")
    await (await waitForSelector(page, "#ecard-rebind")).tap()
    await waitForSelector(page, "#ecard-bind-panel")
  })

  await runCase("宿舍搜索关键词为空时提示且不发请求", async () => {
    await clearStorage()
    await seedSession()
    // 把 rooms 故意设成 500：若真的发了请求，页面会显示服务端文案而不是本地校验提示。
    await mockScenario({
      "GET /ecard/summary": { statusCode: 200, data: ECARD_NOT_BOUND },
      "GET /ecard/rooms": { statusCode: 500, data: { detail: "空关键词不应发起请求" } }
    })

    const page = await miniProgram.reLaunch("/pages/ecard/index")
    await (await waitForSelector(page, "#ecard-bind-open")).tap()
    await (await waitForSelector(page, "#ecard-room-search")).tap()

    const error = await waitForSelector(page, "#ecard-search-error")
    assertEqual(await error.text(), "请输入楼栋或房间号关键词", "空关键词提示")
  })

  await runCase("绑定失败时展示服务端文案", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({
      "GET /ecard/summary": { statusCode: 200, data: ECARD_NOT_BOUND },
      "POST /ecard/binding": { statusCode: 400, data: { detail: "无效宿舍标识" } }
    })

    const page = await miniProgram.reLaunch("/pages/ecard/index")
    await (await waitForSelector(page, "#ecard-bind-open")).tap()
    await (await waitForSelector(page, "#ecard-room-keyword")).input("A1")
    await (await waitForSelector(page, "#ecard-room-search")).tap()
    await (await waitForSelector(page, "#ecard-room-bind-0")).tap()

    const error = await waitForSelector(page, "#ecard-bind-error")
    assertEqual(await error.text(), "无效宿舍标识", "绑定失败文案")
  })

  await runCase("服务端 5xx 时展示错误文案", async () => {
    await clearStorage()
    await seedSession()
    // mockWxMethod 的函数形式只能通过返回值生效（回调会被序列化丢弃），
    // 因此这里模拟服务端 5xx 来驱动页面错误态；wx fail 分支由逻辑单测覆盖。
    await miniProgram.mockWxMethod("request", serverErrorMock)

    const page = await miniProgram.reLaunch("/pages/grades/index")
    const error = await waitForSelector(page, "#grades-error")
    const text = await error.text()
    assert(
      text.indexOf("服务暂时不可用") !== -1,
      `成绩页应展示服务端错误文案，实际：${text}`
    )
  })

  await runCase("周课表支持周次切换、全部课程与课程详情", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()

    const page = await miniProgram.reLaunch("/pages/schedule/index")
    await waitForSelector(page, "#schedule-period-picker")
    await waitForSelectorCount(page, ".week-row", 16)
    await (await waitForSelector(page, "#schedule-next-week")).tap()
    const nextWeek = await waitForSelector(page, "#schedule-week-picker")
    assert(/^第[2-9][0-9]*周 ▾$/.test(await nextWeek.text()), "下一周按钮应更新周次")

    await (await waitForSelector(page, "#schedule-mode-all")).tap()
    await waitForSelectorCount(page, ".course-card", 3)
    await (await waitForSelector(page, ".course-card")).tap()
    const detail = await waitForSelector(page, "#schedule-course-modal")
    assert((await detail.text()).indexOf("高等数学") !== -1, "课程详情应展示课程名称")
    await (await waitForSelector(page, "#schedule-course-close")).tap()

    await (await waitForSelector(page, "#schedule-mode-week")).tap()
    await (await waitForSelector(page, "#schedule-week-picker")).tap()
    const options = await waitForSelectorCount(page, ".week-option", 30)
    assert(options.length === 30, "周次选择器应提供 1 至 30 周")
    await options[0].tap()
    await waitForSelectorCount(page, "#schedule-week-modal", 0)
  })

  await runCase("浮动调课入口支持选课与预览撤销云端批量历史", async () => {
    await clearStorage()
    await seedSession()
    const record = {
      clientId: "batch-page", year: 2026, term: 1,
      sourceDate: "2026-09-07", targetDate: "2026-09-15",
      sourceOccurrenceKeys: [], targetConflictKeys: [], conflictMode: "swap",
      status: "active", revision: 1,
      moves: [
        { sourceDate: "2026-09-07", targetDate: "2026-09-15", sourceStart: 2, sourceEnd: 2, targetStart: 1 },
        { sourceDate: "2026-09-21", targetDate: "2026-09-29", sourceStart: 2, sourceEnd: 2, targetStart: 1 }
      ]
    }
    await mockScenario({ "GET /settings/schedule/adjustments/v3": { statusCode: 200, data: [record] } })
    const schedule = await miniProgram.reLaunch("/pages/schedule/index")
    await (await waitForSelector(schedule, "#schedule-floating-menu")).tap()
    await (await waitForSelector(schedule, "#schedule-menu-adjustments")).tap()
    const page = await waitForPage("/pages/schedule-adjustments/index")
    await (await waitForSelector(page, "#adjustment-entry-course")).tap()
      await waitForSelector(page, "#adjustment-primary")
    await (await waitForSelector(page, "#adjustment-back")).tap()
    await (await waitForSelector(page, "#adjustment-entry-history")).tap()
    await (await waitForSelector(page, "#adjustment-record-0")).tap()
    const restored = { ...record, status: "restored", revision: 2 }
    await mockScenario({
      "GET /settings/schedule/adjustments/v3": { statusCode: 200, data: [restored] },
      "POST /settings/schedule/adjustments/v3/batch-page/restore-preview": { statusCode: 200, data: { fingerprint: "a".repeat(64), blockers: [], before: [], after: [] } },
      "POST /settings/schedule/adjustments/v3/batch-page/restore": { statusCode: 200, data: restored }
    })
    await miniProgram.mockWxMethod("showModal", { confirm: true, cancel: false })
    await (await waitForSelector(page, "#adjustment-undo-0")).tap()
    await (await waitForSelector(page, "#adjustment-undo-confirm")).tap()
    await waitForSelectorCount(page, "#adjustment-undo-confirm", 0)
    assertEqual((await page.data("records"))[0].status, "restored", "整批调课撤销后仍保留历史")
    await miniProgram.restoreWxMethod("showModal")
  })

  await runCase("整日互换从月历多选到云端确认使用页面内预览", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({})
    const schedule = await miniProgram.reLaunch("/pages/schedule/index")
    await waitForSelector(schedule, "#schedule-week-grid")
    await (await waitForSelector(schedule, "#schedule-floating-menu")).tap()
    await (await waitForSelector(schedule, "#schedule-menu-adjustments")).tap()
    const page = await waitForPage("/pages/schedule-adjustments/index")
    await waitFor(() => page.data("loaded"), "调课工作台加载")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-workbench.png") })
    await (await waitForSelector(page, "#adjustment-entry-day")).tap()
    await (await waitForSelector(page, "#adjustment-source-calendar")).tap()
    await (await waitForSelector(page, "#adjustment-date-2026-08-31")).tap()
    await (await waitForSelector(page, "#adjustment-date-confirm")).tap()
    await (await waitForSelector(page, "#adjustment-target-calendar")).tap()
    await (await waitForSelector(page, "#adjustment-month-next")).tap()
    await (await waitForSelector(page, "#adjustment-date-2026-09-01")).tap()
    await (await waitForSelector(page, "#adjustment-date-confirm")).tap()
    const pair = { sourceDate: "2026-08-31", targetDate: "2026-09-01", sourceStart: 1, sourceEnd: 16, targetStart: 1, sourceKeys: [], action: "swap" }
    const course = { name: "高等数学", teacher: "测试教师", classroom: "教学楼101", weekday: 1, startSection: 1, endSection: 2, week: 1, date: "2026-08-31", itemKey: "course:2026-08-31:math" }
    const moved = { ...course, weekday: 2, date: "2026-09-01", itemKey: "course:2026-08-31:math->2026-09-01" }
    const result = { fingerprint: "b".repeat(64), ready: true, affectedCount: 1, pairs: [{ pair, before: [course], after: [moved], conflicts: [], labels: ["目标为空，来源当天课程将移到目标日期"] }] }
    const record = { clientId: "day-e2e", year: 2026, term: 1, sourceDate: pair.sourceDate, targetDate: pair.targetDate, sourceOccurrenceKeys: [], targetConflictKeys: [], moves: [], conflictMode: "coexist", status: "active", revision: 1, createdAt: "2026-10-01T08:00:00Z", metadata: { request: { schemaVersion: 2, year: 2026, term: 1, firstWeekStart: "2026-08-31", operation: "day", pairs: [pair] }, preview: result } }
    await mockScenario({
      "POST /settings/schedule/adjustments/v3/preview": { statusCode: 200, data: result },
      "POST /settings/schedule/adjustments/v3": { statusCode: 201, data: record },
      "GET /settings/schedule/adjustments/v3": { statusCode: 200, data: [record] }
    })
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    await waitForSelector(page, "#adjustments-submit")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-day-preview.png") })
    await (await waitForSelector(page, "#adjustments-submit")).tap()
    await waitForSelector(page, "#adjustment-record-0")
    assertEqual((await page.data("records"))[0].status, "active", "确认后云端记录生效")
    const state = await miniProgram.evaluate(() => wx.getStorageInfoSync().keys)
    assert(!state.some((key) => key.endsWith("adjustmentDraft.2026.1")), "提交后清理草稿")
  })

  await runCase("按课程同日调课逐步选课并明确选择区间交换", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario({})
    const schedule = await miniProgram.reLaunch("/pages/schedule/index")
    await waitForSelector(schedule, "#schedule-week-grid")
    await (await waitForSelector(schedule, "#schedule-floating-menu")).tap()
    await (await waitForSelector(schedule, "#schedule-menu-adjustments")).tap()
    const page = await waitForPage("/pages/schedule-adjustments/index")
    await waitFor(() => page.data("loaded"), "调课课程加载")
    await (await waitForSelector(page, "#adjustment-entry-course")).tap()
    await (await waitForSelector(page, "#adjustment-course-0")).tap()
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    await (await waitForSelector(page, "#adjustment-target-start-0")).trigger("change", { value: "6" })
    await waitFor(async () => (await page.data("pairs"))[0]?.targetStart === 7, "目标第7节更新")
    const sourceKeys = await page.data("keys")
    const source = (await page.data("courses")).find((c) => sourceKeys.includes(c.itemKey))
    assert(source, "选择具体课程实例")
    const pairRow = (await page.data("pairs"))[0]
    const pair = { sourceDate: pairRow.sourceDate, targetDate: pairRow.targetDate, sourceStart: pairRow.sourceStart, sourceEnd: pairRow.sourceEnd, targetStart: pairRow.targetStart, sourceKeys: pairRow.sourceKeys, action: "choose" }
    const duration = pair.sourceEnd - pair.sourceStart + 1
    const before = { ...source, week: Number(source.weeks) }
    const conflict = { ...before, name: "冲突课程", startSection: 7, endSection: 7 + duration, itemKey: "conflict-course" }
    const initial = { fingerprint: "c".repeat(64), ready: false, affectedCount: 2, pairs: [{ pair, before: [before, conflict], after: [before, conflict], conflicts: [conflict], labels: ["请选择交换或覆盖，尚未确定调整结果"] }] }
    await mockScenario({ "POST /settings/schedule/adjustments/v3/preview": { statusCode: 200, data: initial } })
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    await waitForSelector(page, "#adjustment-action-0-swap")
    const swapped = { ...initial, ready: true, pairs: [{ ...initial.pairs[0], pair: { ...pair, action: "swap" }, after: [{ ...before, startSection: 7, endSection: 6 + duration }, { ...conflict, startSection: pair.sourceStart, endSection: pair.sourceEnd }, { ...conflict, startSection: 7 + duration, endSection: 7 + duration }], labels: ["交换两侧区间全部课程", "跨区间连堂课将拆分，区间外节次保留"] }] }
    await mockScenario({ "POST /settings/schedule/adjustments/v3/preview": { statusCode: 200, data: swapped } })
    await (await waitForSelector(page, "#adjustment-action-0-swap")).tap()
    await waitFor(async () => (await page.data("preview"))?.ready, "交换预览可确认")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-course-swap.png") })
    assertEqual((await page.data("preview")).pairs[0].pair.action, "swap", "明确选择交换后才确认")
  })

  await runCase("跨周多门课程选择保留，周次范围和统一目标即时更新", async () => {
    await clearStorage(); await seedSession(); await mockScenario({})
    const page = await miniProgram.reLaunch("/pages/schedule-adjustments/index?week=1")
    await waitFor(() => page.data("loaded"), "跨周调课加载")
    await (await waitForSelector(page, "#adjustment-course-0")).tap()
    await waitFor(async () => (await page.data("keys")).length === 1, "第一门课程选择")
    const firstKey = (await page.data("keys"))[0]
    await (await waitForSelector(page, "#adjustment-week-next")).tap()
    await (await waitForSelector(page, "#adjustment-course-1")).tap()
    await waitFor(async () => (await page.data("keys")).length === 2, "跨周第二门课程选择")
    assertEqual((await page.data("keys")).length, 2, "跨周选择不丢失")
    await (await waitForSelector(page, "#adjustment-week-prev")).tap()
    assert((await page.data("keys")).includes(firstKey), "返回前周保留实例")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-v3-week-selection.png") })
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    await (await waitForSelector(page, "#adjustment-range-0")).trigger("change", { value: "1" })
    await (await waitForSelector(page, "#adjustment-scope-0-3")).tap()
    await waitFor(async () => (await page.data("keys")).length === 3, "周次范围第三周更新")
    assertEqual((await page.data("keys")).length, 3, "周次网格添加第三周实例")
    await (await waitForSelector(page, "#adjustment-primary")).tap()
    const groups = await page.data("groups")
    for (let i = 0; i < groups.length; i++) {
      const current = await page.data("currentGroup")
      const groupIndex = await page.data("groupIndex")
      await (await waitForSelector(page, `#adjustment-target-weekday-${groupIndex}`)).trigger("change", { value: String(current.weekday % 7) })
      if (i + 1 < groups.length) await (await waitForSelector(page, "#adjustment-group-next")).tap()
    }
    await waitFor(async () => {
      const validation = await page.data("validation")
      if (validation) throw new Error(`各安排统一目标更新失败：${validation}；设置=${JSON.stringify(await page.data("groupSettings"))}；课程=${JSON.stringify(await page.data("pairs"))}`)
      return validation === ""
    }, "各安排统一目标更新")
    assertEqual(await page.data("validation"), "", "不同安排各自设置目标")
    assertEqual((await page.data("pairs")).length, 3, "跨周具体实例展开")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-v3-targets.png") })
    await (await waitForSelector(page, "#adjustment-back")).tap()
    await (await waitForSelector(page, "#adjustment-back")).tap()
    assertEqual((await page.data("keys")).length, 3, "步骤返回保留全部选择")
    const keys = await page.data("keys")
    await miniProgram.reLaunch("/pages/schedule-adjustments/index")
    const recovered = await waitForPage("/pages/schedule-adjustments/index")
    await waitFor(() => recovered.data("loaded"), "跨周草稿恢复")
    assertEqual(JSON.stringify(await recovered.data("keys")), JSON.stringify(keys), "重开恢复多门多周草稿")
  })

  await runCase("整日覆盖展示来源和目标课程，不提供逐课选择", async () => {
    await clearStorage(); await seedSession(); await mockScenario({})
    const page = await miniProgram.reLaunch("/pages/schedule-adjustments/index?week=1")
    await waitFor(() => page.data("loaded"), "按天部分加载")
    await (await waitForSelector(page, "#adjustment-entry-day")).tap()
    await (await waitForSelector(page, "#adjustment-day-cover")).tap()
    await (await waitForSelector(page, "#adjustment-source-calendar")).tap()
    await (await waitForSelector(page, "#adjustment-date-2026-08-31")).tap()
    await waitFor(async () => (await page.data("calendarCourses"))[0]?.count > 0, "日期课程清单更新")
    assert((await page.data("calendarCourses"))[0].count > 0, "月历即时显示当天课程")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-v3-calendar-courses.png") })
    await (await waitForSelector(page, "#adjustment-date-confirm")).tap()
    await (await waitForSelector(page, "#adjustment-target-calendar")).tap()
    await (await waitForSelector(page, "#adjustment-month-next")).tap()
    await (await waitForSelector(page, "#adjustment-date-2026-09-01")).tap()
    await (await waitForSelector(page, "#adjustment-date-confirm")).tap()
    await waitFor(async () => (await page.data("validation")) === "", "整日目标配对更新")
    assertEqual((await page.data("keys")).length, 0, "整日不要求逐门选择课程")
    assert((await page.data("sourceDays"))[0].count > 0, "来源日期展示当天全部课程")
    assertEqual((await page.data("pairs"))[0].action, "replace", "覆盖模式选择整日覆盖操作")
    await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, "adjustment-v3-day-cover.png") })
  })

  await runCase("学期切换保留旧草稿并清空新学期选择", async () => {
    await clearStorage(); await seedSession()
    await miniProgram.evaluate(() => {
      wx.setStorageSync("academic.period", {year:2026,term:1})
      wx.setStorageSync("schedule.DEMO-2026-001.adjustmentDraft.2026.1", {
        schemaVersion:3,year:2026,term:1,firstWeekStart:"2026-08-31",operation:"day",pairs:[],
        sources:["2026-08-31"],targets:[],keys:[],groupSettings:[]
      })
    })
    await mockScenario({
      "GET /settings/academic-period": {statusCode:200,data:{year:2026,term:2}},
      "GET /schedule/effective": {statusCode:200,data:[]}
    })
    const page = await miniProgram.reLaunch("/pages/schedule-adjustments/index")
    await waitFor(() => page.data("loaded"), "新学期调课加载")
    assertEqual((await page.data("period")).term,2,"使用云端当前学期")
    assertEqual((await page.data("sources")).length,0,"旧日期不带入新学期")
    assertEqual((await page.data("keys")).length,0,"旧课程不带入新学期")
    const old = await miniProgram.evaluate(() => wx.getStorageSync("schedule.DEMO-2026-001.adjustmentDraft.2026.1"))
    assertEqual(old.sources[0],"2026-08-31","旧学期草稿独立保留")
  })

  await runCase("个人页支持微信绑定与二次确认解绑", async () => {
    await clearStorage()
    await seedSession()
    await mockScenario()
    await miniProgram.mockWxMethod("login", { code: "wechat-automation-code" })

    const page = await miniProgram.reLaunch("/pages/profile/index")
    await (await waitForSelector(page, "#profile-wechat-bind")).tap()
    await waitForSelector(page, "#profile-wechat-unbind")

    await miniProgram.mockWxMethod("showModal", { confirm: true, cancel: false })
    await (await waitForSelector(page, "#profile-wechat-unbind")).tap()
    await waitForSelector(page, "#profile-wechat-bind")
  })

  await runCase("微信未绑定时一键登录给出学号密码引导", async () => {
    await clearStorage()
    await mockScenario({
      "POST /mini/auth/wechat-login": {
        statusCode: 409,
        data: { detail: { code: "wechat_not_bound", message: "当前微信尚未绑定学校账号" } }
      }
    })
    await miniProgram.mockWxMethod("login", { code: "wechat-unbound-code" })

    const page = await miniProgram.reLaunch("/pages/login/index")
    await agreeLegal(page)
    await (await waitForSelector(page, "#login-wechat")).tap()
    const error = await waitForSelector(page, "#login-error")
    assert((await error.text()).indexOf("尚未绑定") !== -1, "未绑定微信应引导学号密码登录")
  })

  await runCase("无会话访问受保护页面时跳转登录页", async () => {
    await clearStorage()
    await mockScenario()

    // 用 evaluate 触发导航：profile 页在 onShow 里会因为无会话再 reLaunch 到登录页，
    // 若走 automator 的 reLaunch（它会等待页面就绪），就会与这次内部跳转互相等待而超时。
    await miniProgram.evaluate(() => {
      wx.reLaunch({ url: "/pages/profile/index" })
    })
    const page = await waitForPage("/pages/login/index")
    assert(pathMatches(page.path, "/pages/login/index"), "无会话时应回到登录页")
  })
}

// ─── 入口 ────────────────────────────────────────────────────────────

async function main() {
  const cliPath = resolveCliPath()
  log(`开发者工具 CLI：${cliPath}`)
  log(`项目路径：${PROJECT}`)
  log("")

  const started = startAutomation(cliPath, PROJECT)
  if (!started.ok) {
    log("开启开发者工具自动化失败。请依次确认：")
    log("  1. 开发者工具「设置 → 安全设置」已开启服务端口；")
    log("  2. 开发者工具已登录（cli islogin 返回 login=true）；")
    log(`  3. 端口 ${started.port} 未被其他程序占用。`)
    if (started.output) log(`CLI 输出：${started.output}`)
    if (started.error) log(`CLI 错误：${started.error.message}`)
    process.exitCode = 1
    return
  }
  log(`自动化端口：${started.port}`)
  log("")

  try {
    miniProgram = await automator.connect({
      wsEndpoint: `ws://127.0.0.1:${autoPort()}`
    })
  } catch (error) {
    log(`连接自动化端口失败：${error && error.message ? error.message : error}`)
    process.exitCode = 1
    return
  }

  miniProgram.on("console", (message) => {
    consoleBuffer.push(`[console.${message.type}] ${message.args.join(" ")}`)
  })
  miniProgram.on("exception", (error) => {
    consoleBuffer.push(`[exception] ${error.message}\n${error.stack || ""}`)
  })

  try {
    await verifyMockWorks()
  } catch (error) {
    log(`预检失败：${error && error.message ? error.message : error}`)
    log("请在开发者工具中重新编译一次后重跑；若仍失败，请关闭项目窗口再重跑。")
    await miniProgram.disconnect()
    process.exitCode = 1
    return
  }

  await clearStorage()
  await warmUp()

  try {
    await runCases()
  } finally {
    try {
      await miniProgram.restoreWxMethod("request")
    } catch (error) {
      log(`⚠ 恢复 wx.request 失败：${error && error.message}`)
    }
    await miniProgram.disconnect()
  }

  const failed = results.filter((item) => !item.ok)
  log("")
  log(`页面回归结果：${results.length - failed.length}/${results.length} 通过`)
  if (failed.length > 0) {
    log("失败用例：")
    for (const item of failed) log(`  - ${item.name}：${item.detail}`)
    if (consoleBuffer.length > 0) {
      log("")
      log("控制台与异常日志：")
      log(sanitize(consoleBuffer.join("\n")))
    }
    process.exitCode = 1
  }
}

main().catch((error) => {
  log(`页面回归异常终止：${error && error.message ? error.message : error}`)
  process.exitCode = 1
})
