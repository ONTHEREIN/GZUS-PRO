package cn.gzus.pro

import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters

internal data class WidgetDatedCourse(
    val itemKey: String,
    val date: LocalDate,
    val week: Int,
    val weekday: Int,
    val startSection: Int,
    val endSection: Int,
    val time: String,
    val name: String,
    val classroom: String,
    val teacher: String,
) {
    val start: LocalDateTime get() = date.atTime(LocalTime.parse(time.substringBefore('-')))
    val end: LocalDateTime get() = date.atTime(LocalTime.parse(time.substringAfter('-')))

    fun json(now: LocalDateTime): JSONObject = JSONObject()
        .put("itemKey", itemKey).put("date", date.toString()).put("week", week)
        .put("weekday", weekday).put("startSection", startSection).put("endSection", endSection)
        .put("time", time).put("name", name).put("classroom", classroom).put("teacher", teacher)
        .put("ongoing", start <= now && now < end)
}

/** 只投影具体日期实例；空列表权威，不展开或恢复原始周课表。 */
internal fun projectWidgetSchedule(
    payload: JSONArray,
    firstWeekStart: LocalDate,
    now: LocalDateTime,
    zone: ZoneId,
): JSONObject {
    val courses = (0 until payload.length()).map { index ->
        val item = payload.getJSONObject(index)
        val date = LocalDate.parse(item.getString("date"))
        val start = item.getInt("startSection")
        val end = item.getInt("endSection")
        require(start in 1..16 && end in start..16) { "组件课程节次无效" }
        require(item.getInt("weekday") == date.dayOfWeek.value) { "组件课程日期与星期不一致" }
        WidgetDatedCourse(item.getString("itemKey"), date, item.getInt("week"), date.dayOfWeek.value,
            start, end, item.getString("time"), item.getString("name"),
            item.getString("classroom"), item.getString("teacher"))
    }.sortedWith(compareBy({ it.start }, { it.end }))
    val today = courses.filter { it.date == now.toLocalDate() }
    val monday = now.toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    val firstMonday = firstWeekStart.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    val currentWeek = ChronoUnit.WEEKS.between(firstMonday, monday).toInt() + 1
    val weekly = courses.filter { it.date >= monday && it.date < monday.plusDays(7) }
    val next = courses.firstOrNull { it.end > now }
    val time = next?.let { if (it.date == now.toLocalDate()) it.time else "${it.date} ${it.time}" }.orEmpty()
    val status = when {
        next == null -> "none"
        next.start <= now -> "ongoing"
        else -> "upcoming"
    }
    return JSONObject()
        .put("effectiveCoursesJson", payload.toString())
        .put("weeklyCoursesJson", JSONArray(weekly.map { it.json(now) }).toString())
        .put("todayCoursesJson", JSONArray(today.map { course ->
            course.json(now).put("time", course.time.substringBefore('-'))
                .put("info", listOf(course.classroom, course.teacher).filter { it.isNotBlank() }.joinToString(" · "))
        }).toString())
        .put("todayItems", JSONArray(today.map { "${it.time} ${it.name}" }).toString())
        .put("todayTitle", if (today.isEmpty()) "今日无课" else "今日 ${today.size} 节课")
        .put("todayMeta", "第${currentWeek}周 · ${today.size} 节课")
        .put("nextTitle", next?.name ?: "暂无下一节课")
        .put("nextTime", time).put("nextStatus", status)
        .put("nextMeta", if (next == null) "暂无待上课程" else "$time · ${next.classroom}")
        .put("nextDetail", if (next == null) "点击查看课表" else if (status == "ongoing") "进行中" else "待开始")
        .put("nextClassroom", next?.classroom.orEmpty()).put("nextTeacher", next?.teacher.orEmpty())
        .put("nextStartEpochMillis", next?.start?.atZone(zone)?.toInstant()?.toEpochMilli() ?: 0L)
        .put("nextEndEpochMillis", next?.end?.atZone(zone)?.toInstant()?.toEpochMilli() ?: 0L)
}
