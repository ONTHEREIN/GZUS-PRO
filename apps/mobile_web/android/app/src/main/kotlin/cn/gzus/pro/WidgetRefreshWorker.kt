package cn.gzus.pro

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import java.util.concurrent.TimeUnit

private const val WIDGET_REFRESH_WORK_NAME = "gzus-widget-refresh"
private const val WIDGET_REFRESH_ONCE_WORK_NAME = "gzus-widget-refresh-once"
private const val WIDGET_REFRESH_PREFS = "gzus_widget_refresh"
private const val WIDGET_HOME_PREFS = "gzus_home_widgets"

object WidgetRefreshScheduler {
    private const val KEY_BASE_URL = "baseUrl"
    private const val KEY_SESSION_ID = "sessionId"
    private const val KEY_YEAR = "year"
    private const val KEY_TERM = "term"
    private const val KEY_WEEK = "week"
    private const val KEY_ETAG = "etag"
    private const val KEY_LAST_TRIGGER = "lastTrigger"

    fun configure(context: Context, baseUrl: String, sessionId: String, year: Int, term: Int, week: Int) {
        require(baseUrl.isNotBlank()) { "组件刷新 API 地址不能为空" }
        require(sessionId.isNotBlank()) { "组件刷新会话不能为空" }
        require(year > 0) { "组件刷新学年无效：$year" }
        require(term in 1..2) { "组件刷新学期无效：$term" }
        require(week > 0) { "组件刷新周次无效：$week" }
        prefs(context).edit()
            .putString(KEY_BASE_URL, baseUrl.trimEnd('/'))
            .putString(KEY_SESSION_ID, sessionId)
            .putInt(KEY_YEAR, year)
            .putInt(KEY_TERM, term)
            .putInt(KEY_WEEK, week)
            .apply()
        enqueue(context)
    }

    fun replaceSession(context: Context, baseUrl: String, sessionId: String) {
        val existing = prefs(context)
        configure(
            context = context,
            baseUrl = baseUrl,
            sessionId = sessionId,
            year = existing.getInt(KEY_YEAR, 0),
            term = existing.getInt(KEY_TERM, 0),
            week = existing.getInt(KEY_WEEK, 0),
        )
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
        WorkManager.getInstance(context).cancelUniqueWork(WIDGET_REFRESH_WORK_NAME)
    }

    fun triggerIfDue(context: Context) {
        if (configuration(context) == null) return
        val preferences = prefs(context)
        val now = System.currentTimeMillis()
        val last = preferences.getLong(KEY_LAST_TRIGGER, 0L)
        if (now - last < 25 * 60 * 1000L) return
        preferences.edit().putLong(KEY_LAST_TRIGGER, now).apply()
        WorkManager.getInstance(context).enqueueUniqueWork(
            WIDGET_REFRESH_ONCE_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build(),
        )
    }

    internal fun configuration(context: Context): WidgetRefreshConfiguration? {
        val prefs = prefs(context)
        val baseUrl = prefs.getString(KEY_BASE_URL, null) ?: return null
        val sessionId = prefs.getString(KEY_SESSION_ID, null) ?: return null
        val year = prefs.getInt(KEY_YEAR, 0)
        val term = prefs.getInt(KEY_TERM, 0)
        val week = prefs.getInt(KEY_WEEK, 0)
        if (baseUrl.isBlank() || sessionId.isBlank() || year <= 0 || term !in 1..2 || week <= 0) return null
        return WidgetRefreshConfiguration(baseUrl, sessionId, year, term, week, prefs.getString(KEY_ETAG, null))
    }

    internal fun saveEtag(context: Context, etag: String?) {
        prefs(context).edit().putString(KEY_ETAG, etag).apply()
    }

    private fun enqueue(context: Context) {
        val request = PeriodicWorkRequestBuilder<WidgetRefreshWorker>(30, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WIDGET_REFRESH_WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    private fun prefs(context: Context) = EncryptedSharedPreferences.create(
        context,
        WIDGET_REFRESH_PREFS,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
}

internal data class WidgetRefreshConfiguration(
    val baseUrl: String,
    val sessionId: String,
    val year: Int,
    val term: Int,
    val week: Int,
    val etag: String?,
)

class WidgetRefreshWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val configuration = WidgetRefreshScheduler.configuration(applicationContext) ?: return@withContext Result.success()
        val connection = (URL("${configuration.baseUrl}/widget-snapshot?year=${configuration.year}&term=${configuration.term}&week=${configuration.week}")
            .openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10_000
            readTimeout = 15_000
            setRequestProperty("X-Session-Id", configuration.sessionId)
            configuration.etag?.let { setRequestProperty("If-None-Match", it) }
        }
        try {
            when (val status = connection.responseCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> Result.success()
                HttpURLConnection.HTTP_UNAUTHORIZED -> {
                    WidgetRefreshScheduler.clear(applicationContext)
                    Result.failure()
                }
                HttpURLConnection.HTTP_OK -> {
                    val body = connection.inputStream.bufferedReader().use { it.readText() }
                    saveSnapshot(JSONObject(body), configuration.week)
                    WidgetRefreshScheduler.saveEtag(applicationContext, connection.getHeaderField("ETag"))
                    HomeWidgetProvider.updateAll(applicationContext)
                    Result.success()
                }
                in 500..599 -> Result.retry()
                else -> throw IllegalStateException("组件刷新失败：HTTP $status")
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun saveSnapshot(snapshot: JSONObject, currentWeek: Int) {
        val modules = snapshot.optJSONObject("modules") ?: throw IllegalStateException("组件快照缺少 modules")
        val prefs = applicationContext.getSharedPreferences(WIDGET_HOME_PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit().putString("widgetSnapshotPayload", snapshot.toString())
        modules.optJSONObject("schedule")?.optJSONArray("data")?.let { schedule ->
            saveWeeklySchedule(editor, schedule, currentWeek)
            saveTodaySchedule(editor, schedule, currentWeek)
        }
        modules.optJSONObject("grades")?.optJSONArray("data")?.let { grades ->
            editor.putString("gradeItemsJson", grades.toString())
            editor.putString("gradeCount", grades.length().toString())
            averageOf(grades, "gradePoint")?.let { editor.putString("gradeGpa", "%.2f".format(it)) }
            averageOf(grades, "score")?.let { editor.putString("gradeAverage", "%.1f".format(it)) }
        }
        modules.optJSONObject("exams")?.optJSONArray("data")?.let { exams ->
            editor.putString("examItemsJson", exams.toString())
            editor.putString("examCount", exams.length().toString())
        }
        modules.optJSONObject("progress")?.optJSONObject("data")?.optJSONArray("items")?.let { items ->
            editor.putString("progressItemsJson", items.toString())
        }
        modules.optJSONObject("ecard")?.optJSONObject("data")?.let { ecard ->
            editor.putString("utilityElectricity", ecard.optString("powerText", "-"))
            editor.putString("utilityColdWater", ecard.optString("coldWaterText", "-"))
            editor.putString("utilityHotWater", ecard.optString("hotWaterText", "-"))
            editor.putString("utilityRoomInfo", ecard.optString("roomDisplay", ""))
        }
        editor.apply()
    }

    private fun saveTodaySchedule(
        editor: android.content.SharedPreferences.Editor,
        courses: org.json.JSONArray,
        currentWeek: Int,
    ) {
        val now = Calendar.getInstance()
        val weekday = ((now.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1
        val today = buildList {
            for (index in 0 until courses.length()) {
                val course = courses.optJSONObject(index) ?: continue
                if (course.optInt("weekday", -1) != weekday || !occursInWeek(course.optString("weeks"), currentWeek)) continue
                val startSection = course.optInt("startSection", 0)
                val endSection = course.optInt("endSection", startSection)
                if (startSection !in 1..SECTION_TIMES.size || endSection !in 1..SECTION_TIMES.size) continue
                val start = SECTION_TIMES[startSection - 1].first
                val end = SECTION_TIMES[endSection - 1].second
                val startMinutes = minutesOf(start)
                val endMinutes = minutesOf(end)
                add(
                    JSONObject()
                        .put("itemKey", "${course.optString("courseId").ifBlank { course.optString("kch_id").ifBlank { course.optString("name", "课程") } }}:$weekday:$startSection")
                        .put("week", currentWeek)
                        .put("weekday", weekday)
                        .put("startSection", startSection)
                        .put("time", start)
                        .put("name", course.optString("name", "课程"))
                        .put("info", listOf(course.optString("classroom"), course.optString("teacher")).filter { it.isNotBlank() }.joinToString(" · "))
                        .put("ongoing", nowMinutes(now) in startMinutes until endMinutes)
                        .put("startMinutes", startMinutes)
                        .put("endMinutes", endMinutes),
                )
            }
        }.sortedBy { it.optInt("startMinutes") }
        val nowValue = nowMinutes(now)
        val next = today.firstOrNull { it.optInt("endMinutes") > nowValue }
        val tomorrowWeekday = weekday % 7 + 1
        val hasTomorrow = (0 until courses.length()).any { index ->
            val course = courses.optJSONObject(index) ?: return@any false
            course.optInt("weekday", 0) == tomorrowWeekday &&
                occursInWeek(course.optString("weeks"), currentWeek)
        }
        val noTodayOrTomorrow = today.isEmpty() && !hasTomorrow
        val nextTitle = if (noTodayOrTomorrow) "今明无课" else next?.optString("name") ?: "暂无下一节课"
        editor
            .putString("todayCoursesJson", org.json.JSONArray(today).toString())
            .putString("todayTitle", if (today.isEmpty()) "今日无课" else "今日 ${today.size} 节课")
            .putString("todayMeta", "第${currentWeek}周 · ${today.size} 节课")
            .putString("todayItems", org.json.JSONArray(today.map { "${it.optString("time")} ${it.optString("name")}" }).toString())
            .putString("nextTitle", nextTitle)
            .putString("nextTime", if (noTodayOrTomorrow) "" else next?.optString("time") ?: "")
            .putString("nextMeta", if (noTodayOrTomorrow) "今日、明日暂无课程" else next?.let { "${it.optString("time")} · ${it.optString("info")}" } ?: "今天没有更多课程")
            .putString("nextDetail", if (next == null || noTodayOrTomorrow) "点击查看课表" else if (next.optBoolean("ongoing")) "进行中" else "待开始")
            .putString("nextClassroom", if (noTodayOrTomorrow) "" else next?.optString("info") ?: "")
            .putString("nextTeacher", "")
            .putString("nextStatus", when {
                noTodayOrTomorrow || next == null -> "none"
                next.optBoolean("ongoing") -> "ongoing"
                else -> "upcoming"
            })
    }

    private fun saveWeeklySchedule(
        editor: android.content.SharedPreferences.Editor,
        courses: org.json.JSONArray,
        currentWeek: Int,
    ) {
        val result = org.json.JSONArray()
        for (index in 0 until courses.length()) {
            val course = courses.optJSONObject(index) ?: continue
            val weekday = course.optInt("weekday", 0)
            val startSection = course.optInt("startSection", 0)
            val endSection = course.optInt("endSection", startSection)
            if (weekday !in 1..7 || startSection !in 1..SECTION_TIMES.size || endSection !in startSection..SECTION_TIMES.size) continue
            if (!occursInWeek(course.optString("weeks"), currentWeek)) continue
            val source = course.optString("courseId").ifBlank {
                course.optString("kch_id").ifBlank { course.optString("courseCode").ifBlank { course.optString("name", "课程") } }
            }
            result.put(
                JSONObject()
                    .put("itemKey", "$source:$weekday:$startSection")
                    .put("week", currentWeek)
                    .put("weekday", weekday)
                    .put("startSection", startSection)
                    .put("endSection", endSection)
                    .put("time", "${SECTION_TIMES[startSection - 1].first}-${SECTION_TIMES[endSection - 1].second}")
                    .put("name", course.optString("name", "课程"))
                    .put("classroom", course.optString("classroom"))
                    .put("teacher", course.optString("teacher"))
                    .put("ongoing", false),
            )
        }
        editor.putString("weeklyCoursesJson", result.toString())
    }

    private fun occursInWeek(spec: String, week: Int): Boolean {
        if (spec.isBlank()) return true
        if (spec.contains("单") && week % 2 == 0) return false
        if (spec.contains("双") && week % 2 != 0) return false
        val ranges = Regex("(\\d+)\\s*[-~至]\\s*(\\d+)").findAll(spec)
            .map { it.groupValues[1].toInt()..it.groupValues[2].toInt() }
            .toList()
        if (ranges.any { week in it }) return true
        return Regex("\\d+").findAll(spec).any { it.value.toInt() == week }
    }

    private fun minutesOf(value: String): Int {
        val parts = value.split(':')
        return parts[0].toInt() * 60 + parts[1].toInt()
    }

    private fun nowMinutes(calendar: Calendar): Int =
        calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)

    private fun averageOf(items: org.json.JSONArray, key: String): Double? {
        val values = buildList {
            for (index in 0 until items.length()) {
                items.optJSONObject(index)?.optString(key)?.toDoubleOrNull()?.let(::add)
            }
        }
        return values.takeIf { it.isNotEmpty() }?.average()
    }
}

private val SECTION_TIMES = listOf(
    "09:00" to "09:40", "09:40" to "10:20", "10:40" to "11:20", "11:20" to "12:00",
    "12:30" to "13:10", "13:10" to "13:50", "14:00" to "14:40", "14:40" to "15:20",
    "15:30" to "16:10", "16:10" to "16:50", "17:00" to "17:40", "17:40" to "18:20",
    "19:00" to "19:40", "19:40" to "20:20", "20:30" to "21:10", "21:10" to "21:50",
)
