package cn.gzus.pro

/** 实况通知文本与生命周期的纯函数，供通知构建和单元测试共用。 */
object LiveUpdateTextFormatter {
    fun summary(payload: LiveUpdatePayload): String {
        return when {
            payload.isCountdown && !payload.courseName.isNullOrBlank() -> payload.courseName!!
            payload.body.isNotBlank() -> payload.body
            else -> payload.title
        }
    }

    fun detail(payload: LiveUpdatePayload): String {
        val lines = mutableListOf<String>()
        when (payload.type) {
            "course_reminder", "exam_reminder" -> {
                addLine(lines, payload.courseName)
                addLine(lines, payload.location)
                if (payload.type == "exam_reminder" && !payload.seat.isNullOrBlank()) {
                    addLine(lines, "座位 ${payload.seat}")
                }
            }
            "grade_update" -> {
                if (!payload.score.isNullOrBlank()) addLine(lines, "成绩：${payload.score}")
                if (!payload.gradeStatus.isNullOrBlank()) {
                    addLine(lines, payload.gradeStatus)
                } else if (payload.gradePassed != null) {
                    addLine(lines, if (payload.gradePassed == true) "合格" else "不及格")
                }
            }
            "ecard_reminder" -> {
                payload.utilityMetrics.forEach { metric ->
                    val marker = if (metric.isAlert) "⚠️ " else ""
                    addLine(lines, "$marker${metric.label}：${metric.value}")
                }
            }
        }
        addLine(lines, payload.body)
        return if (lines.isEmpty()) payload.title else lines.distinct().joinToString("\n")
    }

    fun primaryValue(payload: LiveUpdatePayload): String? {
        return when (payload.type) {
            "grade_update" -> payload.score
            "ecard_reminder" -> payload.utilityPrimaryValue
                ?: payload.utilityMetrics.firstOrNull { it.isAlert }?.value
                ?: payload.utilityMetrics.firstOrNull()?.value
            else -> null
        }
    }

    fun timeoutMillis(endTimeMillis: Long, nowMillis: Long): Long {
        return (endTimeMillis - nowMillis).coerceAtLeast(0L)
    }

    private fun addLine(lines: MutableList<String>, value: String?) {
        val normalized = value?.trim().orEmpty()
        if (normalized.isNotEmpty()) lines += normalized
    }
}
