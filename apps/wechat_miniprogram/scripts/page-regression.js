#!/usr/bin/env node
/**
 * 微信开发者工具页面回归（miniprogram-automator）。
 *
 * 覆盖：空输入校验、错误密码、登录成功、首页/课表/成绩/考试/通知/生活缴费/个人信息
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
  await miniProgram.evaluate(() => {
    wx.setStorageSync("auth.sessionId", "automation-session-id")
    wx.setStorageSync("auth.studentName", "演示同学")
    wx.setStorageSync("auth.studentId", "DEMO-2026-001")
  })
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

async function fillLoginForm(page, account, password) {
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
  await runCase("空输入时提示学号密码必填且不写入会话", async () => {
    await clearStorage()
    await mockScenario()
    const page = await miniProgram.reLaunch("/pages/login/index")
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

    const exams = await waitForSelectorCount(home, ".home-exam-row", 2)
    assert(exams.length === 2, "首页应展示 2 条考试提醒")

    const error = await home.$("#home-error")
    assert(!error, "首页不应出现错误态")
  })

  await runCase("课表、成绩、考试、通知、生活缴费、个人信息均完成加载", async () => {
    const targets = [
      { path: "/pages/schedule/index", items: ".course-block", count: 3, error: "#schedule-error", label: "课表" },
      { path: "/pages/grades/index", items: ".grade-card", count: 2, error: "#grades-error", label: "成绩" },
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
