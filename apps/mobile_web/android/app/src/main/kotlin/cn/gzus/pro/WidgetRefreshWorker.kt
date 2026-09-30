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
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID
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
    private const val KEY_GENERATION = "generation"
    private const val KEY_SCHEDULE_CONTEXT = "scheduleContext"
    private const val KEY_FIRST_WEEK_START = "firstWeekStart"

    fun configure(context: Context, baseUrl: String, sessionId: String, year: Int, term: Int, week: Int, scheduleContext: String, firstWeekStart: Long): Unit = WidgetRefreshTransactions.update {
        require(baseUrl.isNotBlank()) { "组件刷新 API 地址不能为空" }
        require(sessionId.isNotBlank()) { "组件刷新会话不能为空" }
        require(year > 0) { "组件刷新学年无效：$year" }
        require(term in 1..2) { "组件刷新学期无效：$term" }
        require(firstWeekStart > 0) { "组件刷新缺少开学日期" }
        JSONObject(scheduleContext)
        require(week > 0) { "组件刷新周次无效：$week" }
        prefs(context).edit()
            .putString(KEY_BASE_URL, baseUrl.trimEnd('/'))
            .putString(KEY_SESSION_ID, sessionId)
            .putInt(KEY_YEAR, year)
            .putInt(KEY_TERM, term)
            .putInt(KEY_WEEK, week)
            .putString(KEY_SCHEDULE_CONTEXT, scheduleContext)
            .putLong(KEY_FIRST_WEEK_START, firstWeekStart)
            .putString(KEY_GENERATION, UUID.randomUUID().toString())
            .remove(KEY_ETAG)
            .remove(KEY_LAST_TRIGGER)
            .apply()
        enqueue(context)
    }

    fun replaceSession(context: Context, baseUrl: String, sessionId: String): Unit = WidgetRefreshTransactions.update {
        val existing = prefs(context)
        configure(
            context = context,
            baseUrl = baseUrl,
            sessionId = sessionId,
            year = existing.getInt(KEY_YEAR, 0),
            term = existing.getInt(KEY_TERM, 0),
            week = existing.getInt(KEY_WEEK, 0),
            scheduleContext = existing.getString(KEY_SCHEDULE_CONTEXT, null) ?: throw IllegalArgumentException("组件刷新缺少课表上下文"),
            firstWeekStart = existing.getLong(KEY_FIRST_WEEK_START, 0L),
        )
    }

    fun clear(context: Context): Unit = WidgetRefreshTransactions.update {
        prefs(context).edit().clear().apply()
        applicationWidgetPrefs(context).edit().clear().apply()
        val workManager = WorkManager.getInstance(context)
        workManager.cancelUniqueWork(WIDGET_REFRESH_WORK_NAME)
        workManager.cancelUniqueWork(WIDGET_REFRESH_ONCE_WORK_NAME)
        HomeWidgetProvider.updateAll(context)
    }

    fun triggerIfDue(context: Context): Unit = WidgetRefreshTransactions.update {
        if (configuration(context) == null) return@update
        val preferences = prefs(context)
        val now = System.currentTimeMillis()
        val last = preferences.getLong(KEY_LAST_TRIGGER, 0L)
        if (now - last < 25 * 60 * 1000L) return@update
        preferences.edit().putLong(KEY_LAST_TRIGGER, now).apply()
        WorkManager.getInstance(context).enqueueUniqueWork(
            WIDGET_REFRESH_ONCE_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build(),
        )
    }

    internal fun configuration(context: Context): WidgetRefreshConfiguration? = WidgetRefreshTransactions.update {
        val prefs = prefs(context)
        val baseUrl = prefs.getString(KEY_BASE_URL, null) ?: return@update null
        val sessionId = prefs.getString(KEY_SESSION_ID, null) ?: return@update null
        val generation = prefs.getString(KEY_GENERATION, null) ?: return@update null
        val scheduleContext = prefs.getString(KEY_SCHEDULE_CONTEXT, null) ?: return@update null
        val firstWeekStart = prefs.getLong(KEY_FIRST_WEEK_START, 0L)
        val year = prefs.getInt(KEY_YEAR, 0)
        val term = prefs.getInt(KEY_TERM, 0)
        val week = prefs.getInt(KEY_WEEK, 0)
        if (baseUrl.isBlank() || sessionId.isBlank() || year <= 0 || term !in 1..2 || week <= 0 || firstWeekStart <= 0) return@update null
        WidgetRefreshConfiguration(baseUrl, sessionId, year, term, week, prefs.getString(KEY_ETAG, null), generation, scheduleContext, firstWeekStart)
    }

    internal fun commitResponse(context: Context, requestedConfiguration: WidgetRefreshConfiguration, persist: () -> Unit): Boolean =
        WidgetRefreshTransactions.commit(requestedConfiguration.generation, { configuration(context)?.generation }, persist)

    internal fun saveEtag(context: Context, etag: String?) {
        prefs(context).edit().putString(KEY_ETAG, etag).apply()
    }

    internal fun saveSchedule(
        editor: android.content.SharedPreferences.Editor,
        courses: org.json.JSONArray,
        configuration: WidgetRefreshConfiguration,
    ) {
        val zone = ZoneId.systemDefault()
        val firstWeekStart = Instant.ofEpochMilli(configuration.firstWeekStart).atZone(zone).toLocalDate()
        val projected = projectWidgetSchedule(courses, firstWeekStart, LocalDateTime.now(zone), zone)
        for (key in projected.keys()) {
            if (key.endsWith("EpochMillis")) editor.putLong(key, projected.getLong(key))
            else editor.putString(key, projected.getString(key))
        }
    }

    internal fun refreshCachedSchedule(context: Context): Unit = WidgetRefreshTransactions.update {
        val configuration = configuration(context) ?: return@update
        val preferences = applicationWidgetPrefs(context)
        val raw = preferences.getString("effectiveCoursesJson", null)
            ?: throw IllegalStateException("组件刷新缺少生效课程缓存")
        val editor = preferences.edit()
        saveSchedule(editor, org.json.JSONArray(raw), configuration)
        editor.apply()
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

    private fun applicationWidgetPrefs(context: Context) =
        context.getSharedPreferences(WIDGET_HOME_PREFS, Context.MODE_PRIVATE)
}

internal data class WidgetRefreshConfiguration(
    val baseUrl: String,
    val sessionId: String,
    val year: Int,
    val term: Int,
    val week: Int,
    val etag: String?,
    val generation: String,
    val scheduleContext: String,
    val firstWeekStart: Long,
)

class WidgetRefreshWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val configuration = WidgetRefreshScheduler.configuration(applicationContext) ?: return@withContext Result.success()
        val connection = (URL("${configuration.baseUrl}/widget-snapshot")
            .openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            connectTimeout = 10_000
            readTimeout = 15_000
            setRequestProperty("X-Session-Id", configuration.sessionId)
            configuration.etag?.let { setRequestProperty("If-None-Match", it) }
        }
        try {
            connection.outputStream.use { it.write(configuration.scheduleContext.toByteArray(Charsets.UTF_8)) }
            when (val status = connection.responseCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> {
                    WidgetRefreshScheduler.commitResponse(applicationContext, configuration) {
                        val prefs = applicationContext.getSharedPreferences(WIDGET_HOME_PREFS, Context.MODE_PRIVATE)
                        val cached = prefs.getString("effectiveCoursesJson", null) ?: throw IllegalStateException("组件 304 响应缺少生效课程缓存")
                        val editor = prefs.edit()
                        WidgetRefreshScheduler.saveSchedule(editor, org.json.JSONArray(cached), configuration)
                        editor.apply()
                        HomeWidgetProvider.updateAll(applicationContext)
                    }
                    Result.success()
                }
                HttpURLConnection.HTTP_UNAUTHORIZED -> {
                    WidgetRefreshScheduler.commitResponse(applicationContext, configuration) {
                        WidgetRefreshScheduler.clear(applicationContext)
                    }
                    Result.failure()
                }
                HttpURLConnection.HTTP_OK -> {
                    val body = connection.inputStream.bufferedReader().use { it.readText() }
                    val snapshot = JSONObject(body)
                    WidgetRefreshScheduler.commitResponse(applicationContext, configuration) {
                        saveSnapshot(snapshot, configuration)
                        WidgetRefreshScheduler.saveEtag(applicationContext, connection.getHeaderField("ETag"))
                        HomeWidgetProvider.updateAll(applicationContext)
                    }
                    Result.success()
                }
                in 500..599 -> Result.retry()
                else -> throw IllegalStateException("组件刷新失败：HTTP $status")
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun saveSnapshot(snapshot: JSONObject, configuration: WidgetRefreshConfiguration) {
        require(snapshot.getString("scheduleFormat") == "dated-v1") { "组件快照不是带日期的生效课表" }
        val modules = snapshot.optJSONObject("modules") ?: throw IllegalStateException("组件快照缺少 modules")
        val prefs = applicationContext.getSharedPreferences(WIDGET_HOME_PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit().putString("widgetSnapshotPayload", snapshot.toString())
        val scheduleModule = modules.getJSONObject("schedule")
        if (scheduleModule.getString("status") == "error") {
            throw IllegalStateException("组件课表读取失败：${scheduleModule.optString("error")}")
        }
        WidgetRefreshScheduler.saveSchedule(editor, scheduleModule.getJSONArray("data"), configuration)
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

    private fun averageOf(items: org.json.JSONArray, key: String): Double? {
        val values = buildList {
            for (index in 0 until items.length()) {
                items.optJSONObject(index)?.optString(key)?.toDoubleOrNull()?.let(::add)
            }
        }
        return values.takeIf { it.isNotEmpty() }?.average()
    }
}
