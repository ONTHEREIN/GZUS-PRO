import { GradeItem } from "./models"

export interface GradeResult {
  resultKind: "passed" | "failed" | "pending" | "unknown"
  resultText: string
}

/** 判定来自服务端公共逻辑，客户端不另设及格规则。 */
export function gradeResult(grade: GradeItem): GradeResult {
  if (grade.gradePassed === true) return { resultKind: "passed", resultText: "及格" }
  if (grade.gradePassed === false) return { resultKind: "failed", resultText: "不及格" }
  const pendingTexts = ["待公布", "未公布", "待发布", "未发布", "暂未公布"]
  if (!grade.score?.trim() || pendingTexts.includes(grade.score.trim()) || pendingTexts.includes(grade.gradeStatus?.trim() || "")) return { resultKind: "pending", resultText: "待公布" }
  return { resultKind: "unknown", resultText: "无法判断" }
}
