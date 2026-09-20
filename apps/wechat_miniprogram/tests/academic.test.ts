import { strict as assert } from "node:assert"
import { test } from "node:test"

import { syncAcademicPeriod } from "../utils/academic"

type RequestResponse = { statusCode: number; data: unknown }
type GlobalWithWx = typeof globalThis & { wx?: unknown }

test("并发同步学期只发起一组请求", async () => {
  const requests: string[] = []
  const responses: Array<(response: RequestResponse) => void> = []
  const store = new Map<string, unknown>()
  ;(globalThis as GlobalWithWx).wx = {
    getAccountInfoSync: () => ({ miniProgram: { envVersion: "develop" } }),
    getStorageSync: (key: string) => store.get(key) ?? "",
    setStorageSync: (key: string, value: unknown) => store.set(key, value),
    request: (options: {
      url: string
      success: (response: RequestResponse) => void
    }) => {
      requests.push(options.url)
      responses.push(options.success)
    }
  }

  const first = syncAcademicPeriod()
  const second = syncAcademicPeriod()
  assert.equal(first, second)
  assert.equal(requests.length, 1)

  responses.shift()!({ statusCode: 200, data: { year: null, term: null } })
  await new Promise<void>((resolve) => setImmediate(resolve))
  assert.equal(requests.length, 2)
  responses.shift()!({ statusCode: 200, data: { year: 2026, term: 1 } })
  assert.deepEqual(await first, { year: 2026, term: 1 })
})
