/** 从完整协议生成随包发布的内容；文档是唯一维护源。 */
import { readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { createHash } from "node:crypto"
import { marked } from "marked"

const documents = {}
for (const [type, filename, title] of [
  ["terms", "terms-of-service.md", "用户服务协议"],
  ["privacy", "privacy-policy.md", "隐私政策"]
]) {
  const markdown = readFileSync(new URL(`../../../docs/${filename}`, import.meta.url), "utf8")
  documents[type] = { title, html: marked.parse(markdown, { async: false }) }
}
const version = createHash("sha256").update(JSON.stringify(documents)).digest("hex")
const directory = new URL("../utils/generated/", import.meta.url)
mkdirSync(directory, { recursive: true })
const outputs = [
  ["legal.ts", `// 自动生成，请修改 docs 中的完整协议。\nexport const legalVersion = ${JSON.stringify(version)}\nexport const legalDocuments = ${JSON.stringify(documents)} as const\n`],
  ["version.json", JSON.stringify({ version }) + "\n"]
]
for (const [name, content] of outputs) {
  const target = fileURLToPath(new URL(name, directory))
  // 内容不变时不触发开发者工具重新编译，以免清除页面回归的请求 mock。
  if (!existsSync(target) || readFileSync(target, "utf8") !== content) writeFileSync(target, content)
}
