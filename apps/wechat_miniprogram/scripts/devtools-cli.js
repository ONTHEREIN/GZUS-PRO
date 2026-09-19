/**
 * 微信开发者工具 CLI 路径解析。
 *
 * 开发者工具必须先在「设置 → 安全设置」中开启服务端口，CLI 才能与之通信。
 * 可用环境变量 WECHAT_DEVTOOLS_CLI 覆盖默认安装路径。
 */

const fs = require("node:fs")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const CANDIDATES = {
  darwin: [
    "/Applications/wechatwebdevtools.app/Contents/MacOS/cli",
    path.join(process.env.HOME || "", "Applications/wechatwebdevtools.app/Contents/MacOS/cli")
  ],
  win32: [
    "C:\\Program Files (x86)\\Tencent\\微信web开发者工具\\cli.bat",
    "C:\\Program Files\\Tencent\\微信web开发者工具\\cli.bat"
  ],
  linux: ["/opt/wechat-devtools/bin/cli"]
}

/** 返回可用的 CLI 可执行文件路径；找不到时抛错并给出排查提示。 */
function resolveCliPath() {
  const override = process.env.WECHAT_DEVTOOLS_CLI
  if (override) {
    if (!fs.existsSync(override)) {
      throw new Error(`WECHAT_DEVTOOLS_CLI 指向的文件不存在：${override}`)
    }
    return override
  }

  const candidates = CANDIDATES[process.platform] || []
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) return candidate
  }

  throw new Error(
    [
      `未找到微信开发者工具 CLI（平台：${process.platform}）。`,
      `已尝试：${candidates.join("、") || "无默认路径"}`,
      "请安装开发者工具，或用 WECHAT_DEVTOOLS_CLI 环境变量指定 CLI 路径。"
    ].join("\n")
  )
}

/** 小程序项目根目录（本文件位于 <project>/scripts/ 下）。 */
function projectRoot() {
  return path.resolve(__dirname, "..")
}

/**
 * 测试产物目录（截图、日志、预览包信息）。
 *
 * 必须位于项目目录**之外**：开发者工具监听项目目录，往项目里写文件会触发重新编译，
 * AppService 重载后注入的 `wx.request` mock 会失效，页面回归随即成片假失败。
 * 可用 WECHAT_TEST_ARTIFACT_DIR 覆盖。
 */
function artifactDir() {
  const override = process.env.WECHAT_TEST_ARTIFACT_DIR
  if (override) return path.resolve(override)
  return path.resolve(projectRoot(), "..", "onegzus-miniprogram-test-artifacts")
}

/** 自动化监听端口，可用 WECHAT_AUTO_PORT 覆盖。 */
function autoPort() {
  const raw = Number(process.env.WECHAT_AUTO_PORT)
  return Number.isInteger(raw) && raw > 0 ? raw : 9420
}

/**
 * 通过 CLI 打开项目并开启自动化端口。
 *
 * 比 `automator.launch` 更可控：端口已被上一个进程占用时 launch 会直接断开连接，
 * 而 `cli auto` 会重新绑定并复用已有窗口。
 */
function startAutomation(cliPath, projectPath) {
  const port = autoPort()
  const result = spawnSync(
    cliPath,
    ["auto", "--project", projectPath, "--auto-port", String(port)],
    { encoding: "utf8", timeout: 180000 }
  )
  return {
    ok: result.status === 0 && !result.error,
    port,
    output: `${result.stdout || ""}${result.stderr || ""}`.trim(),
    error: result.error
  }
}

module.exports = { resolveCliPath, projectRoot, artifactDir, autoPort, startAutomation }
