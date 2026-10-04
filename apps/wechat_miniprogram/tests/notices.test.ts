import { strict as assert } from "node:assert"
import { test } from "node:test"
import { noticePlainText, resolveNoticeCover } from "../utils/notices"

test("通知正文保留段落、解码实体并剔除脚本", () => {
  assert.equal(noticePlainText('<p>选课 &amp; 考试</p><script>secret()</script><p>&#x4e2d;&#25991;<br>下一行&nbsp;&lt;说明&gt;</p>'), "选课 & 考试\n中文\n下一行 <说明>")
  assert.equal(noticePlainText("<div> </div>"), "")
  assert.equal(noticePlainText("&#x110000;"), "&#x110000;")
})

test("管理员封面使用当前环境 API，拒绝无效相对路径", () => {
  assert.match(resolveNoticeCover("/admin/notices/1/image", "https://test-api.onrein.top/api"), /\/api\/admin\/notices\/1\/image$/)
  assert.equal(resolveNoticeCover("https://example.com/image", "https://test-api.onrein.top/api"), "https://example.com/image")
  assert.throws(() => resolveNoticeCover("//other.example/image", "https://test-api.onrein.top/api"), /封面地址无效/)
})
