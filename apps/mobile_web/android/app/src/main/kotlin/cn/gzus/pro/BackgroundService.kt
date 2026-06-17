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
        const val KEY_APP_FOREGROUND = "appForeground"
        const val KEY_PENDING_OPEN = "pendingOpen"
        const val KEY_LAST_RESTART_TIME = "lastRestartTime"
        const val KEY_RESTART_COUNT = "restartCount"
        const val RESTART_COOLDOWN_MS = 60_000L // 1分钟内不重复重启
        const val RESTART_COUNT_WINDOW_MS = 300_000L // 5分钟内
        const val MAX_RESTART_COUNT = 3 // 5分钟内最多重启3次
        const val EXTRA_API_BASE_URL = "apiBaseUrl"
        const val EXTRA_SESSION_ID = "sessionId"
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
                scheduleKeepAlive(this)
                checkAppProcessAlive()
                CourseReminderScheduler(this).scheduleAll()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopPolling()
        if (!stoppingByUser) {
            scheduleKeepAlive(this)
        } else {
            cancelKeepAlive(this)
        }
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val apiBaseUrl = prefs.getString(KEY_API_BASE_URL, null)
        val sessionId = prefs.getString(KEY_SESSION_ID, null)

        // Check if we can restart (anti-loop protection)
        if (!canRestartService(this)) {
            super.onTaskRemoved(rootIntent)
            return
        }

        // Record restart attempt
        recordRestartAttempt(this)

        // Immediate restart via Handler
        Handler(Looper.getMainLooper()).postDelayed({
            val restartIntent = Intent(this, BackgroundService::class.java).apply {
                action = ACTION_START
                if (apiBaseUrl != null) putExtra(EXTRA_API_BASE_URL, apiBaseUrl)
                if (sessionId != null) putExtra(EXTRA_SESSION_ID, sessionId)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(restartIntent)
                } else {
                    startService(restartIntent)
                }
            } catch (_: Exception) {
                // Service start failed (e.g. quota exhausted), ignore
            }
        }, 1000L)

        // AlarmManager fallback restart via KeepAliveReceiver
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val fallbackIntent = Intent(this, KeepAliveReceiver::class.java).apply {
            action = ACTION_KEEP_ALIVE
        }
        val fallbackPendingIntent = PendingIntent.getBroadcast(
            this,
            KEEP_ALIVE_REQUEST_CODE,
            fallbackIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val triggerTime = SystemClock.elapsedRealtime() + 5000L
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerTime,
                    fallbackPendingIntent
                )
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerTime,
                    fallbackPendingIntent
                )
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerTime,
                fallbackPendingIntent
            )
        } else {
            alarmManager.setExact(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerTime,
                fallbackPendingIntent
            )
        }

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
        val apiBaseUrl = prefs.getString(KEY_API_BASE_URL, null)?.trimEnd('/') ?: return
        val sessionId = prefs.getString(KEY_SESSION_ID, null)?.takeIf { it.isNotBlank() } ?: return
        val messages = fetchMessages(apiBaseUrl, sessionId)
        if (messages != null) {
            consecutiveFailures = 0
            pollIntervalSeconds = 30L
            val appForeground = prefs.getBoolean(KEY_APP_FOREGROUND, false)
            for (index in 0 until messages.length()) {
                val message = messages.optJSONObject(index) ?: continue
                val isLiveUpdate = message.optBoolean("liveUpdate", false) ||
                    (message.optJSONObject("extras")?.optBoolean("liveUpdate", false) ?: false)
                if (isLiveUpdate || !appForeground) {
                    showPushNotification(message)
                }
            }
        } else {
            consecutiveFailures++
            pollIntervalSeconds = minOf(300L, pollIntervalSeconds * 2)
        }
        executor?.schedule({ pollOnce() }, pollIntervalSeconds, TimeUnit.SECONDS)
    }

    private fun fetchMessages(apiBaseUrl: String, sessionId: String): JSONArray? {
        val connection = (URL("$apiBaseUrl/push/poll").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10000
            readTimeout = 10000
            setRequestProperty("X-Session-Id", sessionId)
        }
        return try {
            val status = connection.responseCode
            if (status !in 200..299) return null
            val reader = BufferedReader(InputStreamReader(connection.inputStream, Charsets.UTF_8))
            val body = reader.use { it.readText() }
            JSONObject(body).optJSONArray("messages")
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun showPushNotification(message: JSONObject) {
        val title = message.optString("title", "软帮手通知")
        val body = message.optString("body", "")
        val extras = message.optJSONObject("extras") ?: JSONObject().apply {
            put("type", message.optString("type", ""))
            put("url", message.optString("url", ""))
        }
        val liveUpdate = message.optBoolean("liveUpdate", false)
        val style = message.optString("style", "metric")
        val endTime = message.optLong("endTime", 0L)
        val progressStartTime = message.optLong("progressStartTime", System.currentTimeMillis())
        val progressMax = message.optInt("progressMax", 0)
        val progressCurrent = message.optInt("progressCurrent", 0)
        val ongoing = message.optBoolean("ongoing", style != "metric")
        val shortCriticalText = message.optString("shortCriticalText", "").ifBlank { null }

        // Try live update notification first
        if (liveUpdate) {
            try {
                val helper = LiveUpdateNotificationHelper(this)
                val notificationKey = message.optString("id").ifBlank { "${System.currentTimeMillis()}" }
                val posted = helper.postLiveUpdate(
                    id = notificationKey.hashCode(),
                    title = title,
                    body = body,
                    style = style,
                    endTimeMillis = endTime,
                    shortCriticalText = shortCriticalText,
                    extrasJson = extras.toString(),
                    ongoing = ongoing,
                    progressMax = if (style == "progress" && endTime > 0L) 100 else progressMax,
                    progressCurrent = if (style == "progress" && endTime > 0L) {
                        timeProgress(progressStartTime, endTime)
                    } else {
                        progressCurrent
                    },
                )
                if (posted) {
                    val cancelTime = if (style == "metric") System.currentTimeMillis() + 30 * 60 * 1000L else endTime
                    if (ongoing && style == "progress" && endTime > System.currentTimeMillis()) {
                        scheduleProgressUpdates(
                            helper = helper,
                            notificationId = notificationKey.hashCode(),
                            title = title,
                            body = body,
                            endTimeMillis = endTime,
                            startTimeMillis = progressStartTime,
                            shortCriticalText = shortCriticalText,
                            extrasJson = extras.toString(),
                        )
                    }
                    scheduleLiveUpdateCancel(notificationKey.hashCode(), cancelTime)
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
        val notificationKey = message.optString("id").ifBlank { "${System.currentTimeMillis()}" }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationKey.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(notificationKey.hashCode(), notification)
        } catch (_: SecurityException) {
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
        notificationId: Int,
        title: String,
        body: String,
        startTimeMillis: Long,
        endTimeMillis: Long,
        shortCriticalText: String?,
        extrasJson: String,
    ) {
        val handler = Handler(Looper.getMainLooper())
        fun postNext() {
            if (endTimeMillis <= System.currentTimeMillis()) return
            helper.postLiveUpdate(
                id = notificationId,
                title = title,
                body = body,
                style = "progress",
                endTimeMillis = endTimeMillis,
                shortCriticalText = shortCriticalText,
                extrasJson = extrasJson,
                ongoing = true,
                progressMax = 100,
                progressCurrent = timeProgress(startTimeMillis, endTimeMillis),
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
