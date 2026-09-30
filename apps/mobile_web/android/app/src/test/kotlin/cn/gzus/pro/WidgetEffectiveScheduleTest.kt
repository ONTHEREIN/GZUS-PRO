package cn.gzus.pro

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetEffectiveScheduleTest {
    private fun course(date: String, week: Int, key: String): JSONObject = JSONObject()
        .put("itemKey", key).put("date", date).put("week", week)
        .put("weekday", LocalDate.parse(date).dayOfWeek.value)
        .put("startSection", 1).put("endSection", 2).put("time", "09:00-10:20")
        .put("name", "数学").put("teacher", "老师").put("classroom", "A101")
        .put("ongoing", false)

    @Test
    fun datedCoursesCrossWeekAndReprojectWithoutRecyclingPastCourses() {
        val payload = JSONArray().put(course("2026-09-07", 1, "past"))
            .put(course("2026-09-14", 2, "moved"))
        val first = LocalDate.parse("2026-09-07")
        val sunday = projectWidgetSchedule(payload, first, LocalDateTime.parse("2026-09-13T20:00"), ZoneId.of("UTC"))
        assertEquals("past", JSONArray(sunday.getString("weeklyCoursesJson")).getJSONObject(0).getString("itemKey"))
        assertEquals("upcoming", sunday.getString("nextStatus"))
        assertTrue(sunday.getString("nextTime").startsWith("2026-09-14"))
        val monday = projectWidgetSchedule(payload, first, LocalDateTime.parse("2026-09-14T09:10"), ZoneId.of("UTC"))
        assertEquals("ongoing", monday.getString("nextStatus"))
        assertEquals(1, JSONArray(monday.getString("todayCoursesJson")).length())
        assertEquals("第2周 · 1 节课", monday.getString("todayMeta"))
        val nextWeek = projectWidgetSchedule(payload, first, LocalDateTime.parse("2026-09-21T08:00"), ZoneId.of("UTC"))
        assertEquals("none", nextWeek.getString("nextStatus"))
        assertEquals("[]", nextWeek.getString("weeklyCoursesJson"))
    }

    @Test
    fun authoritativeEmptyScheduleClearsEveryCourseView() {
        val projection = projectWidgetSchedule(JSONArray(), LocalDate.parse("2026-09-07"),
            LocalDateTime.parse("2026-09-14T09:10"), ZoneId.of("UTC"))
        assertEquals("[]", projection.getString("effectiveCoursesJson"))
        assertEquals("[]", projection.getString("todayCoursesJson"))
        assertEquals("[]", projection.getString("weeklyCoursesJson"))
        assertEquals("none", projection.getString("nextStatus"))
        assertEquals(0L, projection.getLong("nextStartEpochMillis"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidDateWeekdayPairFailsInsteadOfDisplayingOriginalSchedule() {
        val invalid = course("2026-09-14", 2, "invalid").put("weekday", 7)
        projectWidgetSchedule(JSONArray().put(invalid), LocalDate.parse("2026-09-07"),
            LocalDateTime.parse("2026-09-14T09:10"), ZoneId.of("UTC"))
    }
}
