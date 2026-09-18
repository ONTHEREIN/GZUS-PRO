package cn.gzus.pro

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.UUID

class BackgroundService : Service() {
    companion object {
        const val CHANNEL_ID = "gzus_pro_foreground"
        const val NOTIFICATION_CHANNEL_ID = "gzus_pro_notifications_native"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "cn.gzus.pro.action.START_FOREGROUND_SERVICE"
        const val ACTION_STOP = "cn.gzus.pro.action.STOP_FOREGROUND_SERVICE"
        const val ACTION_KEEP_ALIVE = "cn.gzus.pro.action.KEEP_ALIVE"
        const val KEY_KEEP_ALIVE = "keep_alive"
        const val KEEP_ALIVE_INTERVAL_MS = 300_000L
        const val KEEP_ALIVE_REQUEST_CODE = 2001
        const val PREFS_NAME = "gzus_push_background"
        const val KEY_API_BASE_URL = "apiBaseUrl"
        const val KEY_SESSION_ID = "sessionId"
        const val KEY_INSTALLATION_ID = "installationId"
        const val KEY_APP_FOREGROUND = "appForeground"
        const val KEY_PENDING_OPEN = "pendingOpen"
        const val KEY_LAST_RESTART_TIME = "lastRestartTime"
        const val KEY_RESTART_COUNT = "restartCount"
        private const val FLUTTER_PREFS_NAME = "FlutterSharedPreferences"
        private const val SINGLE_DEVICE_CONFLICT_MESSAGE = "账号已在其他设备登录，请重新登录"
        const val RESTART_COOLDOWN_MS = 60_000L // 1分钟内不重复重启
        const val RESTART_COUNT_WINDOW_MS = 300_000L // 5分钟内
        const val MAX_RESTART_COUNT = 3 // 5分钟内最多重启3次
        const val EXTRA_API_BASE_URL = "apiBaseUrl"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_INSTALLATION_ID = "installationId"
        const val EXTRA_PUSH_EXTRAS = "pushExtras"

        fun storePendingOpen(context: Context, extrasJson: String?) {
            if (extrasJson.isNullOrBlank()) return
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_PENDING_OPEN, extrasJson)
                .apply()
        }

        fun consumePendingOpen(context: Context): Map<String, Any?>? {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val value = prefs.getString(KEY_PENDING_OPEN, null) ?: return null
            prefs.edit().remove(KEY_PENDING_OPEN).apply()
            return jsonObjectToMap(JSONObject(value))
        }

        fun canRestartService(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val lastRestartTime = prefs.getLong(KEY_LAST_RESTART_TIME, 0L)
            val restartCount = prefs.getInt(KEY_RESTART_COUNT, 0)

            // 冷却时间内不允许重启
            if (now - lastRestartTime < RESTART_COOLDOWN_MS) {
                return false
            }

            // 超过窗口期，重置计数器
            if (now - lastRestartTime > RESTART_COUNT_WINDOW_MS) {
                prefs.edit().putInt(KEY_RESTART_COUNT, 0).apply()
                return true
            }

            // 窗口期内重启次数超限
            return restartCount < MAX_RESTART_COUNT
        }

        fun recordRestartAttempt(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val lastRestartTime = prefs.getLong(KEY_LAST_RESTART_TIME, 0L)

            // 超过窗口期，重置计数器
            val newCount = if (now - lastRestartTime > RESTART_COUNT_WINDOW_MS) {
                1
            } else {
                prefs.getInt(KEY_RESTART_COUNT, 0) + 1
            }

            prefs.edit()
                .putLong(KEY_LAST_RESTART_TIME, now)
                .putInt(KEY_RESTART_COUNT, newCount)
                .apply()
        }

        fun hasStoredAuthSession(context: Context): Boolean {
            val flutterPrefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
            return !flutterPrefs.getString("flutter.auth.sessionId", "").isNullOrBlank() ||
                !flutterPrefs.getString("auth.sessionId", "").isNullOrBlank()
        }

        private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
            val map = mutableMapOf<String, Any?>()
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                map[key] = when (val value = json.opt(key)) {
                    is JSONObject -> jsonObjectToMap(value)
                    is JSONArray -> List(value.length()) { index -> value.opt(index) }
                    JSONObject.NULL -> null
                    else -> value
                }
            }
            return map
        }

        @JvmStatic
        fun scheduleKeepAlive(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, KeepAliveReceiver::class.java).apply {
                action = ACTION_KEEP_ALIVE
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                KEEP_ALIVE_REQUEST_CODE,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val triggerTime = SystemClock.elapsedRealtime() + KEEP_ALIVE_INTERVAL_MS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (alarmManager.canScheduleExactAlarms()) {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                } else {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerTime,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerTime,
                    pendingIntent
                )
            }
        }
    }

    private var executor: ScheduledExecutorService? = null
    private var pollIntervalSeconds = 30L
    private var consecutiveFailures = 0
    private var stoppingByUser = false

    private sealed class PollResult {
        data class Success(val messages: JSONArray) : PollResult()
        object Unauthorized : PollResult()
        object Failure : PollResult()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stoppingByUser = true
                stopPolling()
                cancelKeepAlive(this)
                clearConfig()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                saveConfig(intent)
                try {
                    val notification = createForegroundNotification()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                } catch (_: Exception) {
                    stoppingByUser = true
                    stopPolling()
                    stopSelf()
                    return START_NOT_STICKY
                }
                startPolling()
                WidgetRefreshScheduler.triggerIfDue(this)
                checkAppProcessAlive()
                CourseReminderScheduler(this).scheduleAll()
            }
        }
        // 用户划掉任务或系统回收后不由 Service 自动拉起；下次打开 App 时再恢复。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopPolling()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 任务被划掉后仍保留当前服务，但不再把应用误判为前台。
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_APP_FOREGROUND, false)
            .apply()
        super.onTaskRemoved(rootIntent)
    }

    private fun checkAppProcessAlive() {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val runningProcesses = activityManager.runningAppProcesses ?: return
        val isAppForeground = runningProcesses.any {
            it.processName == "cn.gzus.pro" &&
                it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }
        if (!isAppForeground) {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_APP_FOREGROUND, false)
                .apply()
        }
    }

    private fun cancelKeepAlive(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, KeepAliveReceiver::class.java).apply {
            action = ACTION_KEEP_ALIVE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            KEEP_ALIVE_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        alarmManager.cancel(pendingIntent)
    }

    private fun saveConfig(intent: Intent?) {
        val apiBaseUrl = intent?.getStringExtra(EXTRA_API_BASE_URL)?.takeIf { it.isNotBlank() }
        val sessionId = intent?.getStringExtra(EXTRA_SESSION_ID)?.takeIf { it.isNotBlank() }
        if (apiBaseUrl == null && sessionId == null) return
        val editor = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
        if (apiBaseUrl != null) editor.putString(KEY_API_BASE_URL, apiBaseUrl)
        if (sessionId != null) editor.putString(KEY_SESSION_ID, sessionId)
        val installationId = intent?.getStringExtra(EXTRA_INSTALLATION_ID)?.takeIf { it.isNotBlank() }
            ?: getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_INSTALLATION_ID, null)
            ?: UUID.randomUUID().toString()
        editor.putString(KEY_INSTALLATION_ID, installationId)
        editor.apply()
    }

    private fun clearConfig() {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_API_BASE_URL)
            .remove(KEY_SESSION_ID)
            .remove(KEY_PENDING_OPEN)
            .apply()
    }

    private fun startPolling() {
        if (executor != null) return
        pollIntervalSeconds = 30L
        consecutiveFailures = 0
        executor = Executors.newSingleThreadScheduledExecutor()
        executor?.schedule({ pollOnce() }, 2, TimeUnit.SECONDS)
    }

    private fun stopPolling() {
        executor?.shutdownNow()
        executor = null
    }

    private fun pollOnce() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val apiBaseUrl = prefs.getString(KEY_API_BASE_URL, null)?.trimEnd('/')
        val sessionId = prefs.getString(KEY_SESSION_ID, null)?.takeIf { it.isNotBlank() }
        if (apiBaseUrl.isNullOrBlank() || sessionId == null) {
            executor?.schedule({ pollOnce() }, pollIntervalSeconds, TimeUnit.SECONDS)
            return
        }
        if (prefs.getBoolean(KEY_APP_FOREGROUND, false)) {
            executor?.schedule({ pollOnce() }, pollIntervalSeconds, TimeUnit.SECONDS)
            return
        }
        when (val result = fetchMessages(apiBaseUrl, sessionId)) {
            is PollResult.Success -> {
                consecutiveFailures = 0
                pollIntervalSeconds = 30L
                val appForeground = prefs.getBoolean(KEY_APP_FOREGROUND, false)
                val messages = result.messages
                for (index in 0 until messages.length()) {
                    val message = messages.optJSONObject(index) ?: continue
                    val isLiveUpdate = message.optBoolean("liveUpdate", false) ||
                        (message.optJSONObject("extras")?.optBoolean("liveUpdate", false) ?: false)
                    if (isLiveUpdate || !appForeground) {
                        showPushNotification(message)
                    }
                }
            }
            PollResult.Unauthorized -> {
                handleRevokedSession()
                return
            }
            PollResult.Failure -> {
                consecutiveFailures++
                pollIntervalSeconds = minOf(300L, pollIntervalSeconds * 2)
            }
        }
        executor?.schedule({ pollOnce() }, pollIntervalSeconds, TimeUnit.SECONDS)
    }

    private fun fetchMessages(apiBaseUrl: String, sessionId: String): PollResult {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val installationId = prefs.getString(KEY_INSTALLATION_ID, null).orEmpty()
        val connection = (URL("$apiBaseUrl/notifications/events/pending").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10000
            readTimeout = 10000
            setRequestProperty("X-Session-Id", sessionId)
            setRequestProperty("X-Installation-Id", installationId)
        }
        return try {
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_UNAUTHORIZED) return PollResult.Unauthorized
            if (status !in 200..299) {
                val errorBody = connection.errorStream?.let { stream ->
                    BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
                }.orEmpty()
                return if (errorBody.contains(SINGLE_DEVICE_CONFLICT_MESSAGE)) {
                    PollResult.Unauthorized
                } else {
                    PollResult.Failure
                }
            }
            val reader = BufferedReader(InputStreamReader(connection.inputStream, Charsets.UTF_8))
            val body = reader.use { it.readText() }
            if (body.contains(SINGLE_DEVICE_CONFLICT_MESSAGE)) {
                PollResult.Unauthorized
            } else {
                PollResult.Success(JSONObject(body).optJSONArray("events") ?: JSONArray())
            }
        } catch (_: Exception) {
            PollResult.Failure
        } finally {
            connection.disconnect()
        }
    }

    private fun handleRevokedSession() {
        stoppingByUser = true
        stopPolling()
        cancelKeepAlive(this)
        clearConfig()
        clearFlutterAuthState()
        stopForeground(STOP_FOREGROUND_REMOVE)
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun clearFlutterAuthState() {
        val keys = listOf(
            "auth.sessionId",
            "auth.studentName",
            "auth.studentId",
            "auth.ehallCookies",
            "auth.ehallAuthToken",
            "auth.loginMethod",
            "auth.credentialToken",
            "auth.account",
            "auth.password",
            "auth.rememberPassword"
        )
        val editor = getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE).edit()
        keys.forEach { key ->
            editor.remove(key)
            editor.remove("flutter.$key")
        }
        editor.apply()
    }

    private fun showPushNotification(message: JSONObject) {
        val payload = LiveUpdatePayload.fromMessage(message)
        val title = payload.title
        val body = payload.body
        val extras = JSONObject(payload.extrasJson)
        val liveUpdate = message.optBoolean("liveUpdate", false) ||
            extras.optBoolean("liveUpdate", false)

        // Try live update notification first
        if (liveUpdate) {
            try {
                val helper = LiveUpdateNotificationHelper(this)
                val progressPayload = if (payload.style == "progress" && payload.endTimeMillis > 0L) {
                    payload.copy(
                        progressMax = 100,
                        progressCurrent = timeProgress(
                            payload.startTimeMillis,
                            payload.endTimeMillis,
                        ),
                    )
                } else {
                    payload
                }
                val postPayload = if (
                    !progressPayload.ongoing &&
                    progressPayload.style == "metric" &&
                    progressPayload.endTimeMillis <= System.currentTimeMillis()
                ) {
                    progressPayload.copy(
                        endTimeMillis = System.currentTimeMillis() + 30 * 60 * 1000L,
                    )
                } else {
                    progressPayload
                }
                val posted = helper.postLiveUpdate(postPayload)
                if (posted) {
                    if (postPayload.ongoing && postPayload.style == "progress" &&
                        postPayload.endTimeMillis > System.currentTimeMillis()
                    ) {
                        scheduleProgressUpdates(
                            helper = helper,
                            payload = postPayload,
                        )
                    }
                    scheduleLiveUpdateCancel(postPayload.id, postPayload.endTimeMillis)
                    markNotificationPresented(postPayload.eventKey)
                    return
                }
            } catch (_: Exception) {
                // Fall through to regular notification
            }
        }

        // Existing regular notification code
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_PUSH_EXTRAS, extras.toString())
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            payload.id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.drawable.ic_stat_live_update)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(payload.id, notification)
            markNotificationPresented(payload.eventKey)
        } catch (_: SecurityException) {
        }
    }

    private fun markNotificationPresented(eventId: String) {
        if (eventId.isBlank()) return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val apiBaseUrl = prefs.getString(KEY_API_BASE_URL, null)?.trimEnd('/') ?: return
        val sessionId = prefs.getString(KEY_SESSION_ID, null)?.takeIf { it.isNotBlank() } ?: return
        val installationId = prefs.getString(KEY_INSTALLATION_ID, null)?.takeIf { it.isNotBlank() } ?: return
        val connection = (URL(
            "$apiBaseUrl/notifications/events/${Uri.encode(eventId)}/presented"
        ).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 5000
            readTimeout = 5000
            setRequestProperty("X-Session-Id", sessionId)
            setRequestProperty("X-Installation-Id", installationId)
        }
        try {
            connection.responseCode
        } catch (_: Exception) {
            // 下次轮询会再次获取未确认事件。
        } finally {
            connection.disconnect()
        }
    }

    private fun scheduleLiveUpdateCancel(notificationId: Int, endTimeMillis: Long) {
        if (endTimeMillis <= System.currentTimeMillis()) return
        Handler(Looper.getMainLooper()).postDelayed({
            LiveUpdateNotificationHelper(this).cancelLiveUpdate(notificationId)
        }, endTimeMillis - System.currentTimeMillis())
    }

    private fun scheduleProgressUpdates(
        helper: LiveUpdateNotificationHelper,
        payload: LiveUpdatePayload,
    ) {
        val handler = Handler(Looper.getMainLooper())
        fun postNext() {
            if (payload.endTimeMillis <= System.currentTimeMillis()) return
            helper.postLiveUpdate(
                payload.copy(
                    progressMax = 100,
                    progressCurrent = timeProgress(
                        payload.startTimeMillis,
                        payload.endTimeMillis,
                    ),
                ),
            )
            handler.postDelayed({ postNext() }, 60_000L)
        }
        handler.postDelayed({ postNext() }, 60_000L)
    }

    private fun timeProgress(startTimeMillis: Long, endTimeMillis: Long): Int {
        val total = endTimeMillis - startTimeMillis
        if (total <= 0L) return 100
        val elapsed = System.currentTimeMillis() - startTimeMillis
        return ((elapsed.toDouble() / total.toDouble()) * 100.0).toInt().coerceIn(0, 100)
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val foreground = NotificationChannel(
                CHANNEL_ID,
                "后台服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "软帮手后台收消息服务"
                setShowBadge(false)
            }
            val push = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "软帮手通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "教务系统通知推送"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(foreground)
            manager.createNotificationChannel(push)
        }
    }

    private fun createForegroundNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("软帮手正在后台收消息")
            .setContentText("用于接收教务通知和生活缴费提醒")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
            .also {
                it.flags = it.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
            }
    }

}
