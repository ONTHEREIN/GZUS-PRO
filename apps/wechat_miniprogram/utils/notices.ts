/** 正文只展示文本，不执行上游 HTML。 */
export function noticePlainText(value: string): string {
  return value
    .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<(?:br|\/p|\/div|\/li|\/tr|\/h[1-6]|\/blockquote|\/section|\/article)[^>]*>/gi, "\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&(?:nbsp|#160|#x0*a0);/gi, " ")
    .replace(/&#(x[0-9a-f]+|[0-9]+);/gi, (entity: string, code: string): string => {
      const point = code[0].toLowerCase() === "x" ? parseInt(code.slice(1), 16) : parseInt(code, 10)
      return point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? String.fromCodePoint(point) : entity
    })
    .replace(/&(amp|lt|gt|quot|apos);/g, (entity: string): string => {
      const entities: Record<string, string> = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'" }
      return entities[entity]
    })
    .split(/\r?\n/).map((line) => line.replace(/[ \t\f\v\u00a0\u2007\u202f]+/g, " ").trim()).filter(Boolean).join("\n")
}

export function resolveNoticeCover(value: string, apiBaseUrl: string): string {
  if (/^https?:\/\//i.test(value)) return value
  if (!value.startsWith("/admin/notices/")) throw new Error("通知封面地址无效")
  return `${apiBaseUrl}${value}`
}
