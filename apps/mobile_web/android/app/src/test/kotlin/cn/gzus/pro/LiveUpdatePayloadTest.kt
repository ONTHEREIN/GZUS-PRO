package cn.gzus.pro

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveUpdatePayloadTest {
    @Test
    fun courseAndExamUseCountdownAndPreserveLocationAndSeat() {
        val course = LiveUpdatePayload.fromMessage(
            JSONObject()
                .put("id", "course:42")
                .put("type", "course_reminder")
                .put("title", "即将上课")
                .put("body", "高等数学")
                .put("courseName", "高等数学")
                .put("location", "A101")
                .put("startTime", 1_000L)
                .put("endTime", 2_000L)
                .put("style", "progress"),
        )
        assertTrue(course.isCountdown)
        assertEquals("timer", course.renderedStyle)
        assertEquals("高等数学", course.courseName)
        assertEquals("A101", course.location)

        val exam = LiveUpdatePayload.fromMessage(
            JSONObject()
                .put("id", "exam:42")
                .put("type", "exam_reminder")
                .put("startTimeMillis", 1_000L)
                .put("endTimeMillis", 2_000L)
                .put("courseName", "英语")
                .put("examLocation", "B202")
                .put("examSeat", "12号"),
        )
        assertTrue(exam.isCountdown)
        assertEquals("B202", exam.location)
        assertEquals("12号", exam.seat)
    }

    @Test
    fun gradeAndUtilityFieldsAreStructured() {
        val payload = LiveUpdatePayload.fromMessage(
            JSONObject()
                .put("id", "grade:1")
                .put("type", "grade_update")
                .put("grade", JSONObject()
                    .put("score", "88")
                    .put("status", "合格")
                    .put("passed", true))
                .put("utilityMetrics", JSONArray()
                    .put(JSONObject().put("label", "冷水").put("value", "2.0吨").put("isAlert", true))
                    .put(JSONObject().put("label", "电费").put("value", "20元").put("isAlert", false))),
        )
        assertEquals("88", payload.score)
        assertEquals("合格", payload.gradeStatus)
        assertTrue(payload.gradePassed == true)
        assertEquals(2, payload.utilityMetrics.size)
        assertTrue(payload.utilityMetrics.first().isAlert)
        assertEquals("冷水", payload.utilityMetrics.first().label)
        val text = LiveUpdateTextFormatter.detail(payload.copy(type = "ecard_reminder"))
        assertTrue(text.contains("⚠️ 冷水：2.0吨"))
        assertTrue(text.contains("电费：20元"))
        assertEquals(
            "2.0吨",
            LiveUpdateTextFormatter.primaryValue(
                payload.copy(type = "ecard_reminder", utilityPrimaryValue = null),
            ),
        )
        assertEquals("metric", payload.copy(type = "ecard_reminder").renderedStyle)
        assertEquals("metric", payload.renderedStyle)

        val passedOnly = payload.copy(
            gradeStatus = null,
            gradePassed = true,
            type = "grade_update",
        )
        assertTrue(LiveUpdateTextFormatter.detail(passedOnly).contains("合格"))
    }

    @Test
    fun progressIsClampedAndExpiredCountdownFallsBack() {
        val payload = LiveUpdatePayload.fromMessage(
            JSONObject()
                .put("id", "progress:1")
                .put("type", "attendance_update")
                .put("style", "progress")
                .put("progressMax", 100)
                .put("progressCurrent", 999)
                .put("startTime", 3_000L)
                .put("endTime", 2_000L),
        )
        assertEquals(100, payload.progressCurrent)
        assertFalse(payload.isCountdown)
        assertEquals("progress", payload.renderedStyle)
    }

    @Test
    fun methodArgumentsKeepLegacyNumericIdWithoutStructuredEventId() {
        val payload = LiveUpdatePayload.fromMethodArguments(
            mapOf(
                "id" to 42,
                "type" to "new_notice",
                "title" to "通知",
                "body" to "正文",
            ),
        )
        assertEquals(42, payload.id)
        assertFalse(payload.ongoing)
    }

    @Test
    fun unknownTypeGetsOrdinaryDefaultsAndOldAliasesWork() {
        val payload = LiveUpdatePayload.fromMessage(
            JSONObject()
                .put("id", "unknown:1")
                .put("type", "future_event")
                .put("progressStartTime", 1_000L)
                .put("endTime", 2_000L),
        )
        assertEquals("动态", payload.shortCriticalText)
        assertEquals("home", payload.targetTab)
        assertFalse(payload.ongoing)
        assertEquals(0L, LiveUpdateTextFormatter.timeoutMillis(900L, 1_000L))
    }

    @Test
    fun formattedExamAndGradeContainStructuredDetails() {
        val exam = LiveUpdatePayload.fromMessage(
            JSONObject().put("id", "exam:text").put("type", "exam_reminder")
                .put("courseName", "英语").put("location", "B202")
                .put("seat", "12").put("body", "请提前入场"),
        )
        assertTrue(LiveUpdateTextFormatter.detail(exam).contains("英语\nB202\n座位 12"))

        val grade = LiveUpdatePayload.fromMessage(
            JSONObject().put("id", "grade:text").put("type", "grade_update")
                .put("score", "88").put("gradeStatus", "合格"),
        )
        assertTrue(LiveUpdateTextFormatter.detail(grade).contains("成绩：88\n合格"))
    }
}
