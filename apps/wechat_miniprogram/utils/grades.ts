import { GradeItem } from "./models"

export interface GradeResult {
  resultKind: "passed" | "failed" | "pending" | "unknown"
  resultText: string
}

/** 与服务端公共规则一致：先读取明确结论，缺失时使用完整数字成绩的 60 分规则。 */
export function gradeResult(grade: GradeItem): GradeResult {
  const passed = officialGradePassed(grade.gradeStatus) ?? grade.gradePassed
  if (passed === true) return { resultKind: "passed", resultText: "及格" }
  if (passed === false) return { resultKind: "failed", resultText: "不及格" }
  const score = grade.score?.trim() || ""
  const pendingTexts = ["待公布", "未公布", "待发布", "未发布", "暂未公布"]
  if (!score || pendingTexts.includes(score) || pendingTexts.includes(grade.gradeStatus?.trim() || "")) {
    return { resultKind: "pending", resultText: "待公布" }
  }
  const numericText = score.replace(/分$/, "").trim()
  if (/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(numericText)) {
    const numeric = Number(numericText)
    if (Number.isFinite(numeric)) {
      return numeric >= 60 ? { resultKind: "passed", resultText: "及格" } : { resultKind: "failed", resultText: "不及格" }
    }
  }
  return { resultKind: "unknown", resultText: "无法判断" }
}

function officialGradePassed(value: string | null | undefined): boolean | null {
  const status = value?.trim().toLowerCase() || ""
  if (["false", "0", "unqualified"].includes(status) || ["不合格", "不及格", "不通过", "未通过", "挂科", "fail"].some(marker => status.includes(marker))) return false
  if (["true", "1"].includes(status) || ["合格", "及格", "通过", "pass", "qualified"].some(marker => status.includes(marker))) return true
  return null
}
