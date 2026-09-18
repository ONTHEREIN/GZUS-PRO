package cn.gzus.pro

import org.json.JSONArray
import org.json.JSONObject

/**
 * Android 实况通知使用的归一化载荷。
 *
 * WebSocket、Flutter MethodChannel 和本地课程提醒都先转换到这里，避免三条
 * 投递路径对时间、指标和点击参数做出不同解释。
 */
data class LiveUpdateMetric(
    val label: String,
    val value: String,
    val isAlert: Boolean,
)

data class LiveUpdatePayload(
    val id: Int,
    val eventKey: String,
    val type: String,
    val title: String,
    val body: String,
    val style: String,
    val startTimeMillis: Long,
    val endTimeMillis: Long,
    val ongoing: Boolean,
    val shortCriticalText: String?,
    val progressMax: Int,
    val progressCurrent: Int,
    val courseName: String?,
    val location: String?,
    val seat: String?,
    val score: String?,
    val gradeStatus: String?,
    val gradePassed: Boolean?,
    val utilityMetrics: List<LiveUpdateMetric>,
    val utilityPrimaryLabel: String?,
    val utilityPrimaryValue: String?,
    val targetTab: String,
    val deepLink: String?,
    val extrasJson: String,
) {
    val isCountdown: Boolean
        get() = (type == "course_reminder" || type == "exam_reminder") &&
            startTimeMillis > 0L && endTimeMillis > startTimeMillis

    val renderedStyle: String
        get() = when {
            isCountdown -> "timer"
            // 成绩和水电是结构化摘要，即使服务端沿用 progress 传输字段，
            // Android 也应使用标准 BigText/contentInfo 呈现而不是进度条。
            type == "grade_update" || type == "ecard_reminder" -> "metric"
            else -> style
        }

    companion object {
        private val mergedKeys = listOf(
            "id", "eventKey", "type", "title", "body", "style", "startTime",
            "startTimeMillis", "endTime", "endTimeMillis", "ongoing", "shortText",
            "shortCriticalText", "progressStartTime", "progressMax", "progressCurrent",
            "progress", "courseName", "location", "examLocation", "seat", "examSeat",
            "score", "gradeStatus", "gradePassed", "passed", "grade", "utilityMetrics",
            "utilityPrimaryLabel", "utilityPrimaryValue", "targetTab", "url", "deepLink",
            "liveUpdate",
        )

        fun fromMessage(message: JSONObject): LiveUpdatePayload {
            val extras = extrasObject(message)
            val merged = JSONObject()
            copyObject(extras, merged)
            for (key in mergedKeys) {
                if (message.has(key) && !message.isNull(key)) {
                    merged.put(key, message.get(key))
                }
            }
            val type = stringValue(merged, "type") ?: ""
            val style = stringValue(merged, "style") ?: "metric"
            val parsedStartTimeMillis = longValue(
                merged,
                "startTimeMillis",
                "startTime",
                "progressStartTime",
            )
            val endTimeMillis = longValue(merged, "endTimeMillis", "endTime")
            val startTimeMillis = if (parsedStartTimeMillis > 0L) {
                parsedStartTimeMillis
            } else if (style == "progress" && endTimeMillis > 0L) {
                System.currentTimeMillis()
            } else {
                0L
            }
            val ongoingValue = value(merged, "ongoing")
            val ongoing = when (ongoingValue) {
                is Boolean -> ongoingValue
                is Number -> ongoingValue.toInt() != 0
                is String -> ongoingValue.equals("true", ignoreCase = true)
                else -> (type == "course_reminder" || type == "exam_reminder") &&
                    startTimeMillis > 0L && endTimeMillis > startTimeMillis
            }
            val eventId = stringValue(merged, "id")
                ?.takeIf { it.isNotBlank() }
                ?: "live-update-${System.currentTimeMillis()}"
            val eventKey = stringValue(merged, "eventKey")
                ?.takeIf { it.isNotBlank() }
                ?: eventId
            val targetTab = stringValue(merged, "targetTab")
                ?.takeIf { it.isNotBlank() }
                ?: targetTabForType(type)
            val grade = value(merged, "grade") as? JSONObject
            val metrics = metrics(value(merged, "utilityMetrics"))
            val max = intValue(merged, "progressMax")
            val current = intValue(merged, "progressCurrent")
            val normalizedExtras = JSONObject(merged.toString()).apply {
                put("type", type)
                put("targetTab", targetTab)
            }
            return LiveUpdatePayload(
                id = stableId(eventId),
                eventKey = eventKey,
                type = type,
                title = stringValue(merged, "title") ?: "软帮手",
                body = stringValue(merged, "body") ?: "",
                style = style,
                startTimeMillis = startTimeMillis,
                endTimeMillis = endTimeMillis,
                ongoing = ongoing,
                shortCriticalText = stringValue(merged, "shortCriticalText")
                    ?: stringValue(merged, "shortText")
                    ?: defaultShortText(type),
                progressMax = max.coerceAtLeast(0),
                progressCurrent = current.coerceIn(0, max.coerceAtLeast(0)),
                courseName = stringValue(merged, "courseName")
                    ?: stringValue(merged, "name")
                    ?: stringValue(merged, "course"),
                location = stringValue(merged, "location")
                    ?: stringValue(merged, "examLocation"),
                seat = stringValue(merged, "seat")
                    ?: stringValue(merged, "examSeat"),
                score = stringValue(merged, "score") ?: stringValue(grade, "score"),
                gradeStatus = stringValue(merged, "gradeStatus")
                    ?: stringValue(merged, "status")
                    ?: stringValue(grade, "gradeStatus")
                    ?: stringValue(grade, "status"),
                gradePassed = booleanValue(merged, "gradePassed")
                    ?: booleanValue(merged, "passed")
                    ?: booleanValue(grade, "gradePassed")
                    ?: booleanValue(grade, "passed"),
                utilityMetrics = metrics,
                utilityPrimaryLabel = stringValue(merged, "utilityPrimaryLabel"),
                utilityPrimaryValue = stringValue(merged, "utilityPrimaryValue"),
                targetTab = targetTab,
                deepLink = stringValue(merged, "deepLink") ?: stringValue(merged, "url"),
                extrasJson = normalizedExtras.toString(),
            )
        }

        fun fromMethodArguments(arguments: Map<*, *>): LiveUpdatePayload {
            val json = JSONObject()
            for ((key, rawValue) in arguments) {
                if (key !is String || rawValue == null) continue
                if (key == "extras" && rawValue is String) {
                    val extras = runCatching { JSONObject(rawValue) }.getOrNull()
                    if (extras != null) {
                        json.put("extras", extras)
                        continue
                    }
                }
                json.put(key, rawValue)
            }
            // Flutter 侧的整型 id 仅用于通道兼容；结构化 extras 中的事件 id
            // 才是跨 WebSocket、本地提醒和进程重启保持一致的稳定键。
            val extras = json.optJSONObject("extras")
            val eventId = extras?.optString("id")?.trim().orEmpty()
            if (eventId.isNotEmpty()) json.put("id", eventId)
            val payload = fromMessage(json)
            // 保留旧 MethodChannel 调用方传入的整型通知 ID；统一事件载荷
            // 已提供字符串 id 时，仍使用事件键的稳定哈希。
            val numericId = arguments["id"] as? Number
            return if (eventId.isEmpty() && numericId != null) {
                payload.copy(id = numericId.toInt())
            } else {
                payload
            }
        }

        fun fromCourseReminder(
            id: Int,
            title: String,
            body: String,
            courseName: String,
            location: String,
            startTimeMillis: Long,
            endTimeMillis: Long,
            shortCriticalText: String,
            progressCurrent: Int,
            extrasJson: String,
        ): LiveUpdatePayload {
            val message = JSONObject().apply {
                put("id", id.toString())
                put("type", "course_reminder")
                put("title", title)
                put("body", body)
                put("style", "progress")
                put("courseName", courseName)
                put("location", location)
                put("startTime", startTimeMillis)
                put("endTime", endTimeMillis)
                put("shortCriticalText", shortCriticalText)
                put("ongoing", true)
                put("progressMax", 100)
                put("progressCurrent", progressCurrent)
                put("extras", runCatching { JSONObject(extrasJson) }.getOrElse { JSONObject() })
            }
            return fromMessage(message)
        }

        private fun extrasObject(message: JSONObject): JSONObject {
            return when (val raw = message.opt("extras")) {
                is JSONObject -> JSONObject(raw.toString())
                is String -> runCatching { JSONObject(raw) }.getOrElse { JSONObject() }
                else -> JSONObject()
            }
        }

        private fun copyObject(source: JSONObject, target: JSONObject) {
            val keys = source.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                target.put(key, source.get(key))
            }
        }

        private fun value(source: JSONObject?, key: String): Any? {
            if (source == null || !source.has(key) || source.isNull(key)) return null
            return source.get(key)
        }

        private fun stringValue(source: JSONObject?, key: String): String? {
            return value(source, key)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        }

        private fun longValue(source: JSONObject, vararg keys: String): Long {
            for (key in keys) {
                when (val raw = value(source, key)) {
                    is Number -> return raw.toLong()
                    is String -> raw.toLongOrNull()?.let { return it }
                }
            }
            return 0L
        }

        private fun intValue(source: JSONObject, key: String): Int {
            return when (val raw = value(source, key)) {
                is Number -> raw.toInt()
                is String -> raw.toIntOrNull() ?: 0
                else -> 0
            }
        }

        private fun booleanValue(source: JSONObject?, key: String): Boolean? {
            return when (val raw = value(source, key)) {
                is Boolean -> raw
                is Number -> if (raw.toInt() == 0 || raw.toInt() == 1) raw.toInt() == 1 else null
                is String -> when (raw.trim().lowercase()) {
                    "true", "yes", "1", "合格", "通过" -> true
                    "false", "no", "0", "不及格", "不通过", "未通过" -> false
                    else -> null
                }
                else -> null
            }
        }

        private fun metrics(raw: Any?): List<LiveUpdateMetric> {
            val array = raw as? JSONArray ?: return emptyList()
            val result = mutableListOf<LiveUpdateMetric>()
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val label = stringValue(item, "label") ?: continue
                val value = stringValue(item, "value") ?: continue
                result += LiveUpdateMetric(label, value, booleanValue(item, "isAlert") == true)
            }
            return result
        }

        private fun stableId(value: String): Int {
            return value.hashCode().let { if (it == Int.MIN_VALUE) 1 else kotlin.math.abs(it) }
        }

        private fun targetTabForType(type: String): String {
            return when (type) {
                "course_reminder" -> "schedule"
                "exam_reminder" -> "exams"
                "ecard_reminder" -> "ecard"
                "grade_update" -> "grades"
                "new_notice" -> "notices"
                "attendance_update" -> "attendance"
                "business_reminder", "business_update" -> "business"
                else -> "home"
            }
        }

        private fun defaultShortText(type: String): String {
            return when (type) {
                "course_reminder" -> "上课"
                "exam_reminder" -> "考试"
                "grade_update" -> "成绩"
                "ecard_reminder" -> "水电"
                "attendance_update" -> "考勤"
                "business_reminder", "business_update" -> "业务"
                "new_notice" -> "通知"
                else -> "动态"
            }
        }
    }
}
