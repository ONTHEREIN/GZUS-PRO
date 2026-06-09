package cn.gzus.pro

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

class CourseReminderScheduler(private val context: Context) {

    companion object {
        const val PREFS_NAME = "gzus_course_reminders"
        const val KEY_COURSES_JSON = "coursesJson"
        const val KEY_BEFORE_START_MINUTES = "beforeStartMinutes"
        const val KEY_BEFORE_END_MINUTES = "beforeEndMinutes"
        const val KEY_FIRST_WEEK_START = "firstWeekStart"

        private val SECTION_TIMES = listOf(
            "09:00" to "09:40", "09:40" to "10:20",
            "10:40" to "11:20", "11:20" to "12:00",
            "12:30" to "13:10", "13:10" to "13:50",
            "14:00" to "14:40", "14:40" to "15:20",
            "15:30" to "16:10", "16:10" to "16:50",
            "17:00" to "17:40", "17:40" to "18:20",
            "19:00" to "19:40", "19:40" to "20:20",
            "20:30" to "21:10", "21:10" to "21:50",
        )

        fun saveCourseData(
            context: Context,
            coursesJson: String,
            beforeStartMinutes: Int,
            beforeEndMinutes: Int,
            firstWeekStart: String,
        ) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString(KEY_COURSES_JSON, coursesJson)
                .putInt(KEY_BEFORE_START_MINUTES, beforeStartMinutes)
                .putInt(KEY_BEFORE_END_MINUTES, beforeEndMinutes)
                .putString(KEY_FIRST_WEEK_START, firstWeekStart)
                .apply()
            CourseReminderScheduler(context).scheduleAll()
        }
    }

    fun scheduleAll() {
        cancelAll()
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val coursesJson = prefs.getString(KEY_COURSES_JSON, null) ?: return
        val beforeStart = prefs.getInt(KEY_BEFORE_START_MINUTES, 10)
        val beforeEnd = prefs.getInt(KEY_BEFORE_END_MINUTES, 5)
        val firstWeekStart = prefs.getString(KEY_FIRST_WEEK_START, null) ?: return

        val courses: JSONArray
        try {
            courses = JSONArray(coursesJson)
        } catch (_: Exception) { return }

        val now = System.currentTimeMillis()
        val horizonMs = 14L * 24 * 60 * 60 * 1000

        for (i in 0 until courses.length()) {
            val course = courses.optJSONObject(i) ?: continue
            val weekday = course.optInt("weekday", 0)
            val startSection = course.optInt("startSection", 0)
            val endSection = course.optInt("endSection", startSection)
            val name = course.optString("name", "")
            val classroom = course.optString("classroom", "")
            val teacher = course.optString("teacher", "")
            val weeksJson = course.optJSONArray("weeks")
            if (weekday < 1 || weekday > 7 || startSection < 1 || startSection > SECTION_TIMES.size) continue

            val weeks = mutableSetOf<Int>()
            if (weeksJson != null) {
                for (j in 0 until weeksJson.length()) {
                    weeks.add(weeksJson.optInt(j, -1))
                }
            }

            val startTime = SECTION_TIMES[startSection - 1].first
            val endTime = SECTION_TIMES[minOf(endSection, SECTION_TIMES.size) - 1].second

            // Iterate through next 14 days
            for (dayOffset in 0..14) {
                val dayCal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, dayOffset) }
                if (dayCal.get(Calendar.DAY_OF_WEEK) != weekdayToCalendar(weekday)) continue

                val week = weekNumber(firstWeekStart, dayCal)
                if (weeks.isNotEmpty() && week !in weeks) continue

                // Start reminder
                val startReminderTime = dateTime(dayCal, startTime)
                startReminderTime.add(Calendar.MINUTE, -beforeStart)
                if (startReminderTime.timeInMillis > now && startReminderTime.timeInMillis < now + horizonMs) {
                    val classStart = dateTime(dayCal, startTime)
                    val shortText = "${beforeStart}min"
                    val body = "${beforeStart}分钟后：${formatTime(startTime)} $name${if (classroom.isNotBlank()) " · $classroom" else ""}${if (teacher.isNotBlank()) " · $teacher" else ""}"
                    val notificationId = hashId(name, weekday, startSection, startReminderTime.timeInMillis, "start")
                    scheduleAlarm(
                        startReminderTime.timeInMillis,
                        "即将上课",
                        body,
                        classStart.timeInMillis,
                        shortText,
                        notificationId,
                        name,
                    )
                }

                // End reminder
                val endReminderTime = dateTime(dayCal, endTime)
                endReminderTime.add(Calendar.MINUTE, -beforeEnd)
                if (endReminderTime.timeInMillis > now && endReminderTime.timeInMillis < now + horizonMs) {
                    val classEnd = dateTime(dayCal, endTime)
                    val shortText = "${beforeEnd}min"
                    val body = "${beforeEnd}分钟后下课：${formatTime(endTime)} $name"
                    val notificationId = hashId(name, weekday, startSection, endReminderTime.timeInMillis, "end")
                    scheduleAlarm(
                        endReminderTime.timeInMillis,
                        "即将下课",
                        body,
                        classEnd.timeInMillis,
                        shortText,
                        notificationId,
                        name,
                    )
                }
            }
        }
    }

    fun cancelAll() {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // Cancel up to 256 pending alarms by iterating possible IDs
        // We store scheduled IDs in SharedPreferences
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val ids = prefs.getStringSet("scheduled_ids", emptySet()) ?: emptySet()
        for (idStr in ids) {
            val id = idStr.toIntOrNull() ?: continue
            val intent = Intent(context, CourseReminderReceiver::class.java)
            val pendingIntent = PendingIntent.getBroadcast(
                context, id, intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            )
            if (pendingIntent != null) {
                alarmManager.cancel(pendingIntent)
            }
        }
        prefs.edit().remove("scheduled_ids").apply()
    }

    private fun scheduleAlarm(
        triggerTimeMs: Long,
        title: String,
        body: String,
        endTimeMs: Long,
        shortCriticalText: String,
        notificationId: Int,
        courseName: String,
    ) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, CourseReminderReceiver::class.java).apply {
            putExtra(CourseReminderReceiver.EXTRA_TITLE, title)
            putExtra(CourseReminderReceiver.EXTRA_BODY, body)
            putExtra(CourseReminderReceiver.EXTRA_START_TIME_MS, triggerTimeMs)
            putExtra(CourseReminderReceiver.EXTRA_END_TIME_MS, endTimeMs)
            putExtra(CourseReminderReceiver.EXTRA_SHORT_CRITICAL_TEXT, shortCriticalText)
            putExtra(CourseReminderReceiver.EXTRA_NOTIFICATION_ID, notificationId)
            putExtra(CourseReminderReceiver.EXTRA_COURSE_NAME, courseName)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context, notificationId, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerTimeMs, pendingIntent
                )
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerTimeMs, pendingIntent
                )
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, triggerTimeMs, pendingIntent
            )
        } else {
            alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerTimeMs, pendingIntent)
        }

        // Track scheduled ID
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val ids = prefs.getStringSet("scheduled_ids", emptySet())?.toMutableSet() ?: mutableSetOf()
        ids.add(notificationId.toString())
        prefs.edit().putStringSet("scheduled_ids", ids).apply()
    }

    private fun hashId(name: String, weekday: Int, section: Int, timeMs: Long, kind: String): Int {
        return abs((name.hashCode() * 31 + weekday) * 31 + section * 31 + kind.hashCode() * 31 + (timeMs % 100000).toInt())
    }

    private fun weekdayToCalendar(weekday: Int): Int {
        // weekday 1=Monday..7=Sunday -> Calendar.SUNDAY=1..SATURDAY=7
        return when (weekday) {
            1 -> Calendar.MONDAY
            2 -> Calendar.TUESDAY
            3 -> Calendar.WEDNESDAY
            4 -> Calendar.THURSDAY
            5 -> Calendar.FRIDAY
            6 -> Calendar.SATURDAY
            7 -> Calendar.SUNDAY
            else -> Calendar.MONDAY
        }
    }

    private fun weekNumber(firstWeekStart: String, dayCal: Calendar): Int {
        try {
            val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
            val firstWeekDate = sdf.parse(firstWeekStart) ?: return 0
            val firstWeekCal = Calendar.getInstance().apply { time = firstWeekDate }
            // Align to Monday
            while (firstWeekCal.get(Calendar.DAY_OF_WEEK) != Calendar.MONDAY) {
                firstWeekCal.add(Calendar.DAY_OF_YEAR, -1)
            }
            val diffMs = dayCal.timeInMillis - firstWeekCal.timeInMillis
            return (diffMs / (7 * 24 * 60 * 60 * 1000)).toInt() + 1
        } catch (_: Exception) { return 0 }
    }

    private fun dateTime(dayCal: Calendar, hhmm: String): Calendar {
        val parts = hhmm.split(":")
        return (dayCal.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, parts[0].toInt())
            set(Calendar.MINUTE, parts[1].toInt())
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
    }

    private fun formatTime(hhmm: String): String = hhmm
}
