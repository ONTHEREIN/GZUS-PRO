#!/usr/bin/env node
/**
 * CLI 自动预览（`cli auto-preview`）。
 *
 * 「自动预览」会把当前代码编译后直接推送到已开启该功能的微信客户端，
 * 不需要扫码，适合出真机验收包。它要求开发者工具处于登录状态。
 *
 * 使用：
 *   npm run auto-preview
 *   WECHAT_DEVTOOLS_CLI=/path/to/cli npm run auto-preview
 *
 * 退出码：0 成功；1 失败（未登录、未开服务端口、编译错误等）。
 */

const fs = require("node:fs")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const { resolveCliPath, projectRoot, artifactDir } = require("./devtools-cli")

const PROJECT = projectRoot()
const ARTIFACT_DIR = artifactDir()
const INFO_OUTPUT = path.join(ARTIFACT_DIR, "preview-info.json")

/** 调用开发者工具 CLI，返回 { status, stdout, stderr }。 */
function runCli(cliPath, args) {
  const result = spawnSync(cliPath, args, { encoding: "utf8", timeout: 180000 })
  return {
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error
  }
}

function fail(lines) {
  for (const line of lines) process.stderr.write(`${line}\n`)
  process.exitCode = 1
}

function main() {
  let cliPath
  try {
    cliPath = resolveCliPath()
  } catch (error) {
    fail([error.message])
    return
  }

  process.stdout.write(`开发者工具 CLI：${cliPath}\n`)
  process.stdout.write(`项目路径：${PROJECT}\n`)

  const login = runCli(cliPath, ["islogin"])
  const loginOutput = `${login.stdout}${login.stderr}`.trim()

  if (login.status !== 0 || /not\s*login|未登录/i.test(loginOutput)) {
    fail([
      "开发者工具未登录，无法自动预览。",
      `islogin 输出：${loginOutput || "(空)"}`,
      "",
      "请先执行一次登录（会打印二维码，用微信扫码）：",
      `  "${cliPath}" login`,
      "",
      "另外请确认「设置 → 安全设置」已开启服务端口。"
    ])
    return
  }
  process.stdout.write(`登录状态：${loginOutput || "已登录"}\n`)

  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })

  process.stdout.write("正在编译并推送自动预览…\n")
  const preview = runCli(cliPath, [
    "auto-preview",
    "--project",
    PROJECT,
    "--info-output",
    INFO_OUTPUT
  ])

  const output = `${preview.stdout}${preview.stderr}`.trim()
  if (output) process.stdout.write(`${output}\n`)

  if (preview.error) {
    fail([`调用 CLI 失败：${preview.error.message}`])
    return
  }

  if (preview.status !== 0) {
    fail([
      `自动预览失败（CLI 退出码 ${preview.status}）。`,
      "常见原因：编译报错、未开启服务端口、微信客户端未开启「自动预览」。"
    ])
    return
  }

  if (fs.existsSync(INFO_OUTPUT)) {
    process.stdout.write(`预览包信息：${INFO_OUTPUT}\n`)
  }
  process.stdout.write("自动预览已推送，请在手机微信中确认弹出的小程序。\n")
}

main()
