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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopPolling()
                cancelKeepAlive(this)
                clearConfig()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                saveConfig(intent)
                startForeground(NOTIFICATION_ID, createForegroundNotification())
                startPolling()
                scheduleKeepAlive(this)
                checkAppProcessAlive()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopPolling()
        cancelKeepAlive(this)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val apiBaseUrl = prefs.getString(KEY_API_BASE_URL, null)
        val sessionId = prefs.getString(KEY_SESSION_ID, null)

        // Immediate restart via Handler
        Handler(Looper.getMainLooper()).postDelayed({
            val restartIntent = Intent(this, BackgroundService::class.java).apply {
                action = ACTION_START
                if (apiBaseUrl != null) putExtra(EXTRA_API_BASE_URL, apiBaseUrl)
                if (sessionId != null) putExtra(EXTRA_SESSION_ID, sessionId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restartIntent)
            } else {
                startService(restartIntent)
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
                if (!appForeground) {
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
        val title = message.optString("title", "GZUS-PRO 通知")
        val body = message.optString("body", "")
        val extras = message.optJSONObject("extras") ?: JSONObject().apply {
            put("type", message.optString("type", ""))
            put("url", message.optString("url", ""))
        }
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

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val foreground = NotificationChannel(
                CHANNEL_ID,
                "后台服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "GZUS-PRO 后台收消息服务"
                setShowBadge(false)
            }
            val push = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "GZUS-PRO 通知",
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
            .setContentTitle("GZUS-PRO 正在后台收消息")
            .setContentText("用于接收教务通知和生活缴费提醒")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

}
