import { strict as assert } from "node:assert"
import { test } from "node:test"

import {
  PRODUCTION_API_BASE_URL,
  TEST_API_BASE_URL,
  currentEnvVersion,
  resolveApiBaseUrl
} from "../utils/config"

type GlobalWithWx = typeof globalThis & { wx?: unknown }

function installWx(envVersion: unknown): void {
  ;(globalThis as GlobalWithWx).wx = {
    getAccountInfoSync: () => ({ miniProgram: { envVersion } })
  }
}

function installBrokenWx(): void {
  ;(globalThis as GlobalWithWx).wx = {
    getAccountInfoSync: () => {
      throw new Error("基础库不支持 getAccountInfoSync")
    }
  }
}

function clearWx(): void {
  delete (globalThis as GlobalWithWx).wx
}

test("develop 与 trial 使用测试接口地址", () => {
  assert.equal(resolveApiBaseUrl("develop"), TEST_API_BASE_URL)
  assert.equal(resolveApiBaseUrl("trial"), TEST_API_BASE_URL)
})

test("release 使用生产接口地址", () => {
  assert.equal(resolveApiBaseUrl("release"), PRODUCTION_API_BASE_URL)
})

test("测试环境绝不解析到生产地址", () => {
  assert.notEqual(resolveApiBaseUrl("develop"), PRODUCTION_API_BASE_URL)
  assert.notEqual(resolveApiBaseUrl("trial"), PRODUCTION_API_BASE_URL)
})

test("生产环境绝不解析到测试地址", () => {
  assert.notEqual(resolveApiBaseUrl("release"), TEST_API_BASE_URL)
})

test("currentEnvVersion 读取小程序运行版本", () => {
  installWx("develop")
  assert.equal(currentEnvVersion(), "develop")

  installWx("trial")
  assert.equal(currentEnvVersion(), "trial")

  installWx("release")
  assert.equal(currentEnvVersion(), "release")

  clearWx()
})

test("未知运行版本按正式版处理", () => {
  installWx("preview")
  assert.equal(currentEnvVersion(), "release")

  installWx(undefined)
  assert.equal(currentEnvVersion(), "release")

  clearWx()
})

test("缺少 wx 全局时降级到正式版且不抛错", () => {
  clearWx()
  assert.equal(currentEnvVersion(), "release")
  assert.equal(resolveApiBaseUrl(), PRODUCTION_API_BASE_URL)
})

test("getAccountInfoSync 抛错时降级到正式版", () => {
  installBrokenWx()
  assert.equal(currentEnvVersion(), "release")
  clearWx()
})

test("两个接口地址都是 HTTPS 且以 /api 结尾", () => {
  for (const url of [PRODUCTION_API_BASE_URL, TEST_API_BASE_URL]) {
    assert.equal(url.startsWith("https://"), true, url)
    assert.equal(url.endsWith("/api"), true, url)
  }
  assert.notEqual(PRODUCTION_API_BASE_URL, TEST_API_BASE_URL)
})
