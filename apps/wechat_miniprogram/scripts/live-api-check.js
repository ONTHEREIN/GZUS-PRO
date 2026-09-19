#!/usr/bin/env node
/**
 * 真实链路检查：**不 mock** wx.request，用真实账号打测试环境真实域名。
 *
 * 与 `page-regression.js` 的分工：
 *   - page-regression 全程 mock 请求，验证页面逻辑（离线、可进 CI）；
 *   - 本脚本走真实 HTTPS 接口，验证「开发者工具 → test-api.onrein.top → nginx → FastAPI
 *     → 学校 CAS」整条链路，也因此是 **微信 request 合法域名白名单** 的第一道验证。
 *
 * 两种断言档位（MINI_EXPECT）：
 *   demo —— 演示账号，数据是固定 fixture，可以断言具体数值（7 门课、5 条成绩…）；
 *   real —— 真实学生账号，数据不可预知，只做结构性断言：
 *           能登录、页面能加载完、无错误态、未卡在加载中、本地不落任何凭据。
 *
 * 凭据只从环境变量读取，绝不写进文件或日志：
 *   MINI_TEST_ACCOUNT / MINI_TEST_PASSWORD   （兼容旧名 MINI_DEMO_ACCOUNT / MINI_DEMO_PASSWORD）
 *   MINI_EXPECT=demo|real                    （默认 demo）
 *
 * 用法：
 *   MINI_EXPECT=real MINI_TEST_ACCOUNT=... MINI_TEST_PASSWORD=... npm run test:live
 */

const automator = require("miniprogram-automator")

const { resolveCliPath, projectRoot, artifactDir, startAutomation, autoPort } = require("./devtools-cli")

const PROJECT = projectRoot()
const ARTIFACT_DIR = artifactDir()
const PAGE_TIMEOUT_MS = 30000
const POLL_INTERVAL_MS = 200

/** 登录后本地只允许存在这三个键；出现别的键就说明有凭据落盘了。 */
const ALLOWED_STORAGE_KEYS = ["auth.sessionId", "auth.studentName", "auth.studentId"]

const PROFILES = {
  demo: {
    label: "演示账号（固定 fixture，断言具体数值）",
    studentName: "演示同学",
    homeCourseRows: 3,
    homeExamRows: 2,
    scheduleCount: 7,
    gradeCount: 5,
    examCount: 2,
    noticeMin: 3,
    ecardMustContain: "68.4"
  },
  real: {
    label: "真实学生账号（结构性断言：能加载、无错误态、无凭据落盘）",
    studentName: null,
    homeCourseRows: null,
    homeExamRows: null,
    scheduleCount: null,
    gradeCount: null,
    examCount: null,
    noticeMin: 0,
    ecardMustContain: null
  }
}

let miniProgram = null
const consoleBuffer = []
const results = []

// ─── 输出与脱敏 ──────────────────────────────────────────────────────

const SECRETS = [
  process.env.MINI_TEST_PASSWORD,
  process.env.MINI_DEMO_PASSWORD,
  process.env.MINI_TEST_ACCOUNT,
  process.env.MINI_DEMO_ACCOUNT
].filter(Boolean)

function sanitize(text) {
  let out = String(text === null || text === undefined ? "" : text)
  for (const secret of SECRETS) {
    if (secret) out = out.split(secret).join("<redacted>")
  }
  return out
    .replace(/(X-Session-Id"?\s*[:=]\s*"?)[^"',\s}]+/gi, "$1<session-id>")
    .replace(/("?(?:password|sessionId|session_id|credentialToken|authToken|cookie)"?\s*[:=]\s*"?)[^"',\s}]+/gi, "$1<redacted>")
}

function log(message) {
  process.stdout.write(sanitize(message) + "\n")
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}：期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`)
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// ─── 等待工具 ────────────────────────────────────────────────────────

function normalizePath(value) {
  return String(value || "").replace(/^\/+/, "").replace(/\/+$/, "")
}

function pathMatches(actual, expected) {
  const want = normalizePath(expected)
  return want.length > 0 && normalizePath(actual).indexOf(want) !== -1
}

async function waitFor(probe, description, timeoutMs = PAGE_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await probe()
    if (value) return value
    await sleep(POLL_INTERVAL_MS)
  }
  throw new Error(`等待超时（${timeoutMs}ms）：${description}`)
}

async function waitForPage(fragment) {
  const deadline = Date.now() + PAGE_TIMEOUT_MS
  let last = ""
  while (Date.now() < deadline) {
    const page = await miniProgram.currentPage()
    last = page ? page.path : ""
    if (pathMatches(last, fragment)) return page
    await sleep(POLL_INTERVAL_MS)
  }
  throw new Error(`等待页面 ${fragment} 超时（当前：${last || "未知"}）`)
}

async function waitForSelector(page, selector) {
  return waitFor(async () => (await page.$(selector)) || null, `元素 ${selector}`)
}

/**
 * 等到「页面加载完成」：既不能有错误态，也不能还卡在加载中。
 * 出现错误态时立刻抛错（而不是干等到超时），这样报错才有信息量。
 *
 * 关键：`items` 为空数组时在 JS 里是真值，所以「不指定条数」不等于「不检查」。
 * 真实账号档位下，必须**要么看到数据、要么看到页面显式的空态**，否则页面等于白屏。
 */
async function waitForLoaded(page, prefix, itemSelector, expectedCount, emptySelectors = []) {
  return waitFor(async () => {
    const errorElement = await page.$(`#${prefix}-error`)
    if (errorElement) {
      throw new Error(`${prefix} 页面出现错误态：${await errorElement.text()}`)
    }
    const loading = await page.$(`#${prefix}-loading`)
    if (loading) return null

    const items = await page.$$(itemSelector)
    const hasData = items.length > 0

    let hasEmptyState = false
    for (const selector of emptySelectors) {
      if (await page.$(selector)) {
        hasEmptyState = true
        break
      }
    }

    if (!hasData && !hasEmptyState) return null
    if (expectedCount !== null && expectedCount !== undefined && items.length !== expectedCount) {
      return null
    }
    return { items, hasEmptyState }
  }, `${prefix} 页面加载完成（${itemSelector} 有数据，或出现空态）`)
}

function classifyFailure(error) {
  const text = String((error && error.message) || error || "")
  if (/url not in domain list/i.test(text)) {
    return "【白名单】微信 request 合法域名未包含测试域名。请在公众平台加入 https://test-api.onrein.top。"
  }
  if (/账号|密码|认证|captcha|验证码|cas/i.test(text)) {
    return "【凭据/CAS】学校认证未通过。注意：真实账号连续失败可能触发学校侧锁定，请勿反复重试，先人工确认账号密码与验证码。"
  }
  return null
}

async function captureArtifacts(name) {
  try {
    const fs = require("node:fs")
    const path = require("node:path")
    fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
    const safe = name.replace(/[^\w\u4e00-\u9fa5-]/g, "_").slice(0, 60)
    if (miniProgram) {
      await miniProgram.screenshot({ path: path.join(ARTIFACT_DIR, `live-${safe}.png`) })
    }
    fs.writeFileSync(
      path.join(ARTIFACT_DIR, `live-${safe}.log`),
      sanitize(consoleBuffer.join("\n")),
      "utf8"
    )
    log(`    ↳ 现场已保存到 ${ARTIFACT_DIR}/live-${safe}.{png,log}`)
  } catch (error) {
    log(`    ↳ 采集现场失败：${error && error.message}`)
  }
}

async function check(name, fn) {
  try {
    await fn()
    results.push({ name, ok: true })
    log(`✔ ${name}`)
    return true
  } catch (error) {
    const detail = (error && error.message) || String(error)
    results.push({ name, ok: false, detail })
    log(`✖ ${name}`)
    log(`    ${detail}`)
    const hint = classifyFailure(error)
    if (hint) log(`    → ${hint}`)
    await captureArtifacts(name)
    return false
  }
}

// ─── 用例 ────────────────────────────────────────────────────────────

async function runCases(account, password, profile) {
  // 注意：**不要**在没装 mock 的情况下调用 restoreWxMethod——实测它会把 wx.request
  // 弄成非函数，随后所有真实请求都报 "wx.request is not a function"。
  const requestType = await miniProgram.evaluate(() => typeof wx.request)
  assert(
    requestType === "function",
    `wx.request 当前不可用（typeof = ${requestType}）。` +
      "通常是上一次 mock 未干净退出所致：请在开发者工具中重新编译，或关闭项目窗口后重跑。"
  )

  await miniProgram.evaluate(() => {
    wx.clearStorageSync()
  })

  const loggedIn = await check("真实接口登录（不 mock 请求）", async () => {
    const page = await miniProgram.reLaunch("/pages/login/index")
    await (await waitForSelector(page, "#login-account")).input(account)
    await (await waitForSelector(page, "#login-password")).input(password)
    await (await waitForSelector(page, "#login-submit")).tap()

    // 登录可能成功（跳首页）也可能失败（渲染 #login-error）。
    // 等「两者之一」，失败时把页面上的真实原因报出来。
    const outcome = await waitFor(async () => {
      const current = await miniProgram.currentPage()
      if (current && pathMatches(current.path, "/pages/home/index")) return { kind: "home" }
      const errorElement = await page.$("#login-error")
      if (errorElement) return { kind: "error", text: await errorElement.text() }
      return null
    }, "登录结果（进入首页或出现错误提示）")

    if (outcome.kind === "error") {
      throw new Error(`登录失败，页面提示：${outcome.text}`)
    }

    const home = await waitForPage("/pages/home/index")
    const greeting = await waitForSelector(home, "#home-greeting")
    const greetingText = await greeting.text()
    assert(greetingText.trim().length > 0, "首页问候语不应为空")
    if (profile.studentName) {
      assert(
        greetingText.indexOf(profile.studentName) !== -1,
        `首页问候语应显示「${profile.studentName}」，实际：${greetingText}`
      )
    }

    const state = await miniProgram.evaluate(() => ({ sessionId: wx.getStorageSync("auth.sessionId") }))
    assert(state.sessionId, "登录后应写入会话 ID")
  })

  if (!loggedIn) {
    log("")
    log("登录未通过，真实链路验证中止（后续用例都依赖登录态）。")
    log("为避免触发学校侧锁定，脚本不会自动重试。")
    return
  }

  await check("本地存储只保存会话与身份字段（无凭据落盘）", async () => {
    const keys = await miniProgram.evaluate(() => wx.getStorageInfoSync().keys)
    const unexpected = keys.filter((key) => ALLOWED_STORAGE_KEYS.indexOf(key) === -1)
    assertEqual(
      unexpected.length,
      0,
      `本地存储出现预期外的键（可能存在凭据落盘）：${JSON.stringify(unexpected)}`
    )
  })

  let homeEvidence = ""
  await check("首页加载完成且无错误态", async () => {
    const home = await waitForPage("/pages/home/index")
    await waitForSelector(home, "#home-quick-grid")
    const { items, hasEmptyState } = await waitForLoaded(
      home,
      "home",
      ".home-course-row",
      profile.homeCourseRows,
      ["#home-courses-empty"]
    )
    const examRows = await home.$$(".home-exam-row")
    homeEvidence = `近期课程 ${hasEmptyState ? "空态" : `${items.length} 条`}、考试提醒 ${examRows.length} 条`

    if (profile.homeExamRows !== null) {
      assertEqual(examRows.length, profile.homeExamRows, "首页考试提醒条数")
    }
  })
  if (homeEvidence) log(`    ↳ 观测：${homeEvidence}`)

  await check("首页水电余额模块加载完成", async () => {
    const home = await waitForPage("/pages/home/index")
    const card = await waitForSelector(home, "#home-ecard")

    const state = await waitFor(async () => {
      if (await home.$("#home-ecard-loading")) return null
      if (await home.$("#home-ecard-error")) return { kind: "error" }
      if (await home.$("#home-ecard-not-bound")) return { kind: "not_bound" }
      if (await home.$("#home-ecard-power")) return { kind: "ok" }
      return null
    }, "首页水电模块状态")

    if (state.kind === "error") {
      const errorElement = await home.$("#home-ecard-error")
      throw new Error(`首页水电模块报错：${await errorElement.text()}`)
    }

    // 已绑定时三个指标都必须有值，不能是占位符 '-'
    if (state.kind === "ok") {
      for (const [label, selector] of [
        ["电费", "#home-ecard-power"],
        ["冷水", "#home-ecard-cold-water"],
        ["热水", "#home-ecard-hot-water"]
      ]) {
        const text = await (await home.$(selector)).text()
        assert(text.indexOf("-") === -1, `首页${label}应有真实数值，实际：${text}`)
      }
    }

    const text = (await card.text()).replace(/\s+/g, " ")
    log(`    ↳ 观测：首页水电模块（${state.kind}）${text}`)
  })

  const pageCases = [
    {
      name: "课表",
      path: "/pages/schedule/index",
      prefix: "schedule",
      items: ".course-card",
      count: profile.scheduleCount,
      empty: ["#schedule-empty"]
    },
    {
      name: "成绩",
      path: "/pages/grades/index",
      prefix: "grades",
      items: ".grade-card",
      count: profile.gradeCount,
      empty: ["#grades-empty"]
    },
    {
      name: "考试",
      path: "/pages/exams/index",
      prefix: "exams",
      items: ".exam-card",
      count: profile.examCount,
      empty: ["#exams-empty"]
    },
    {
      name: "通知",
      path: "/pages/notices/index",
      prefix: "notices",
      items: ".notice-card",
      count: null,
      empty: ["#notices-empty"]
    },
    {
      name: "生活缴费",
      path: "/pages/ecard/index",
      prefix: "ecard",
      items: "#ecard-summary",
      count: null,
      empty: ["#ecard-not-bound"]
    },
    {
      name: "个人信息",
      path: "/pages/profile/index",
      prefix: "profile",
      items: "#profile-info",
      count: null,
      empty: []
    }
  ]

  for (const item of pageCases) {
    let evidence = ""
    await check(`${item.name}页加载完成`, async () => {
      const page = await miniProgram.reLaunch(item.path)
      await waitForPage(item.path)
      const { items, hasEmptyState } = await waitForLoaded(
        page,
        item.prefix,
        item.items,
        item.count,
        item.empty
      )
      // 记录实际观测到的数据量，作为验收证据（而不只是「通过」二字）。
      evidence = hasEmptyState ? "页面显示空态" : `数据 ${items.length} 条`

      if (item.prefix === "notices" && profile.noticeMin > 0) {
        assert(
          items.length >= profile.noticeMin,
          `通知条数应 ≥ ${profile.noticeMin}，实际 ${items.length}`
        )
      }
      if (item.prefix === "ecard" && profile.ecardMustContain) {
        const text = await items[0].text()
        assert(
          text.indexOf(profile.ecardMustContain) !== -1,
          `生活缴费应包含 ${profile.ecardMustContain}，实际：${text}`
        )
      }
      if (item.prefix === "profile" && profile.studentName) {
        const name = await waitForSelector(page, "#profile-name")
        assertEqual(await name.text(), profile.studentName, "个人信息姓名")
      }
    })
    if (evidence) log(`    ↳ 观测：${item.name} ${evidence}`)
  }

  await check("可在小程序内搜索宿舍（只查询，不绑定）", async () => {
    const page = await miniProgram.reLaunch("/pages/ecard/index")

    // 等页面进入已绑定或未绑定状态，才知道该点哪个入口
    const entry = await waitFor(async () => {
      if (await page.$("#ecard-bind-open")) return "#ecard-bind-open"
      if (await page.$("#ecard-rebind")) return "#ecard-rebind"
      return null
    }, "生活缴费页绑定入口")

    await (await waitForSelector(page, entry)).tap()
    await (await waitForSelector(page, "#ecard-room-keyword")).input("1")
    await (await waitForSelector(page, "#ecard-room-search")).tap()

    // 关键词未必命中，所以断言「查询成功」而不是「一定有结果」：
    // 要么列出宿舍、要么显示空态，但绝不能出现错误态。
    const outcome = await waitFor(async () => {
      const errorElement = await page.$("#ecard-search-error")
      if (errorElement) throw new Error(`宿舍搜索失败：${await errorElement.text()}`)
      const rooms = await page.$$(".room-item")
      if (rooms.length > 0) return { rooms: rooms.length }
      if (await page.$("#ecard-rooms-empty")) return { rooms: 0 }
      return null
    }, "宿舍搜索结果")
    log(`    ↳ 观测：宿舍搜索命中 ${outcome.rooms} 条（只查询，未绑定）`)

    // 关键：按「取消」退出，绝不触发绑定，避免改动真实数据。
    await (await waitForSelector(page, "#ecard-bind-cancel")).tap()
    // setData 到 WXML 生效有延迟，必须等面板真的消失，不能点完就断言。
    await waitFor(
      async () => ((await page.$("#ecard-bind-panel")) ? null : true),
      "绑定面板关闭"
    )
  })

  // 真实绑定：默认不执行，必须显式用 MINI_BIND_ROOM_KEYWORD 指定宿舍关键词才跑。
  // 绑错房间会展示别人房间的读数，所以匹配到多个时**直接中止**而不是随便挑一个。
  const bindKeyword = (process.env.MINI_BIND_ROOM_KEYWORD || "").trim()
  if (bindKeyword) {
    await check(`绑定宿舍「${bindKeyword}」并校验首页余额`, async () => {
      const page = await miniProgram.reLaunch("/pages/ecard/index")
      const entry = await waitFor(async () => {
        if (await page.$("#ecard-bind-open")) return "#ecard-bind-open"
        if (await page.$("#ecard-rebind")) return "#ecard-rebind"
        return null
      }, "生活缴费页绑定入口")
      await (await waitForSelector(page, entry)).tap()
      await (await waitForSelector(page, "#ecard-room-keyword")).input(bindKeyword)
      await (await waitForSelector(page, "#ecard-room-search")).tap()

      const needle = bindKeyword.toLowerCase()
      const matches = await waitFor(async () => {
        const items = await page.$$(".room-item")
        if (items.length === 0) return null
        const found = []
        for (let i = 0; i < items.length; i += 1) {
          const text = await items[i].text()
          if (text.toLowerCase().indexOf(needle) !== -1) found.push({ index: i, text })
        }
        return found.length > 0 ? found : null
      }, `宿舍搜索结果包含 ${bindKeyword}`)

      if (matches.length !== 1) {
        throw new Error(
          `匹配到 ${matches.length} 个宿舍，为避免绑错房间已中止：` +
            JSON.stringify(matches.map((item) => item.text.replace(/\s+/g, " ")))
        )
      }
      log(`    ↳ 即将绑定：${matches[0].text.replace(/\s+/g, " ")}`)

      await (await waitForSelector(page, `#ecard-room-bind-${matches[0].index}`)).tap()

      const summary = await waitForSelector(page, "#ecard-summary")
      log(`    ↳ 绑定后余额：${(await summary.text()).replace(/\s+/g, " ")}`)

      const home = await miniProgram.reLaunch("/pages/home/index")
      const card = await waitForSelector(home, "#home-ecard")
      const power = await waitForSelector(home, "#home-ecard-power")
      const powerText = await power.text()
      assert(powerText.trim().length > 0 && powerText.indexOf("-") === -1, `首页电费应有值，实际：${powerText}`)
      log(`    ↳ 首页水电模块：${(await card.text()).replace(/\s+/g, " ")}`)
    })
  }

  await check("退出登录后回到登录页且本地会话已清空", async () => {
    const page = await miniProgram.reLaunch("/pages/profile/index")
    await waitForSelector(page, "#profile-info")
    await (await waitForSelector(page, "#profile-logout")).tap()
    await waitForPage("/pages/login/index")
    const state = await miniProgram.evaluate(() => ({ sessionId: wx.getStorageSync("auth.sessionId") }))
    assertEqual(state.sessionId, "", "退出后应清空本地会话")
  })
}

// ─── 入口 ────────────────────────────────────────────────────────────

async function main() {
  const account = process.env.MINI_TEST_ACCOUNT || process.env.MINI_DEMO_ACCOUNT
  const password = process.env.MINI_TEST_PASSWORD || process.env.MINI_DEMO_PASSWORD
  const profileKey = (process.env.MINI_EXPECT || "demo").toLowerCase()
  const profile = PROFILES[profileKey]

  if (!profile) {
    process.stderr.write(`MINI_EXPECT 只能是 demo 或 real（当前：${profileKey}）\n`)
    process.exitCode = 1
    return
  }
  if (!account || !password) {
    process.stderr.write(
      "缺少凭据。请通过环境变量传入（不要写进文件或命令行参数）：\n" +
        "  MINI_EXPECT=real MINI_TEST_ACCOUNT=<账号> MINI_TEST_PASSWORD=<密码> npm run test:live\n"
    )
    process.exitCode = 1
    return
  }

  const cliPath = resolveCliPath()
  log(`项目路径：${PROJECT}`)
  log(`目标：真实测试域名（不 mock 请求）　档位：${profile.label}`)

  const started = startAutomation(cliPath, PROJECT)
  if (!started.ok) {
    log(`开启开发者工具自动化失败（端口 ${started.port}）`)
    if (started.output) log(`CLI 输出：${started.output}`)
    process.exitCode = 1
    return
  }

  try {
    miniProgram = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${autoPort()}` })
  } catch (error) {
    log(`连接自动化端口失败：${error && error.message}`)
    process.exitCode = 1
    return
  }

  miniProgram.on("console", (message) => {
    consoleBuffer.push(`[console.${message.type}] ${message.args.join(" ")}`)
  })
  miniProgram.on("exception", (error) => {
    consoleBuffer.push(`[exception] ${error.message}`)
  })

  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      const page = await miniProgram.reLaunch("/pages/login/index")
      await waitForSelector(page, "#login-submit")
      break
    } catch {
      await sleep(1000)
    }
  }

  try {
    await runCases(account, password, profile)
  } finally {
    try {
      await miniProgram.evaluate(() => {
        wx.clearStorageSync()
      })
    } catch {
      /* ignore */
    }
    await miniProgram.disconnect()
  }

  const failed = results.filter((item) => !item.ok)
  log("")
  log(`真实链路结果：${results.length - failed.length}/${results.length} 通过`)
  if (failed.length > 0) {
    log("失败用例：")
    for (const item of failed) log(`  - ${item.name}：${item.detail}`)
    process.exitCode = 1
  }
}

main().catch((error) => {
  log(`真实链路检查异常终止：${(error && error.message) || error}`)
  process.exitCode = 1
})
