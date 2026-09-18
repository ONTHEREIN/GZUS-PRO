package cn.gzus.pro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CourseReminderReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_START_TIME_MS = "startTimeMs"
        const val EXTRA_END_TIME_MS = "endTimeMs"
        const val EXTRA_SHORT_CRITICAL_TEXT = "shortCriticalText"
        const val EXTRA_NOTIFICATION_ID = "notificationId"
        const val EXTRA_COURSE_NAME = "courseName"
        const val EXTRA_LOCATION = "location"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "即将上课"
        val body = intent.getStringExtra(EXTRA_BODY) ?: ""
        val startTimeMs = intent.getLongExtra(EXTRA_START_TIME_MS, System.currentTimeMillis())
        val endTimeMs = intent.getLongExtra(EXTRA_END_TIME_MS, 0L)
        val shortCriticalText = intent.getStringExtra(EXTRA_SHORT_CRITICAL_TEXT) ?: "课程"
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        val courseName = intent.getStringExtra(EXTRA_COURSE_NAME) ?: ""
        val location = intent.getStringExtra(EXTRA_LOCATION) ?: ""

        val extrasJson = org.json.JSONObject().apply {
            put("type", "course_reminder")
            put("courseName", courseName)
            put("style", "progress")
            put("progressStartTime", startTimeMs)
            put("progressMax", 100)
            put("progressCurrent", timeProgress(startTimeMs, endTimeMs))
        }.toString()

        val payload = LiveUpdatePayload.fromCourseReminder(
            id = notificationId,
            title = title,
            body = body,
            courseName = courseName,
            location = location,
            startTimeMillis = startTimeMs,
            endTimeMillis = endTimeMs,
            shortCriticalText = shortCriticalText,
            progressCurrent = timeProgress(startTimeMs, endTimeMs),
            extrasJson = extrasJson,
        )
        val helper = LiveUpdateNotificationHelper(context)
        val posted = helper.postLiveUpdate(payload)
        if (!posted) {
            // Fallback to regular notification
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(BackgroundService.EXTRA_PUSH_EXTRAS, payload.extrasJson)
            }
            val pendingIntent = android.app.PendingIntent.getActivity(
                context, payload.id, clickIntent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )
            val notification = androidx.core.app.NotificationCompat.Builder(context, BackgroundService.NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(R.drawable.ic_stat_live_update)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(androidx.core.app.NotificationCompat.PRIORITY_HIGH)
                .build()
            try {
                manager.notify(payload.id, notification)
            } catch (_: SecurityException) {}
        }

        // Schedule auto-cancel when countdown ends
        if (endTimeMs > System.currentTimeMillis()) {
            val cancelDelay = endTimeMs - System.currentTimeMillis()
            val handler = android.os.Handler(android.os.Looper.getMainLooper())
            fun updateProgress() {
                if (endTimeMs <= System.currentTimeMillis()) return
                helper.postLiveUpdate(
                    payload.copy(
                        progressCurrent = timeProgress(startTimeMs, endTimeMs),
                    ),
                )
                handler.postDelayed({ updateProgress() }, 60_000L)
            }
            handler.postDelayed({ updateProgress() }, 60_000L)
            handler.postDelayed({
                helper.cancelLiveUpdate(payload.id)
            }, cancelDelay)
        }
    }

    private fun timeProgress(startTimeMs: Long, endTimeMs: Long): Int {
        val total = endTimeMs - startTimeMs
        if (total <= 0L) return 100
        val elapsed = System.currentTimeMillis() - startTimeMs
        return ((elapsed.toDouble() / total.toDouble()) * 100.0).toInt().coerceIn(0, 100)
    }
}
