package cn.gzus.pro

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

class LiveUpdateNotificationHelper(private val context: Context) {

    companion object {
        const val CHANNEL_ID = "gzus_pro_live_updates"
        const val CHANNEL_NAME = "实时动态"
        const val CHANNEL_DESCRIPTION = "上下课、考试、水电缴费等实时动态通知"
    }

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = CHANNEL_DESCRIPTION
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * Check whether the app can post promoted notifications (API 35+).
     * On older versions, returns false since promoted notifications are not supported.
     */
    fun canPostPromotedNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            return manager.canPostPromotedNotifications()
        }
        return false
    }

    /**
     * Post a live update notification.
     *
     * @param id Unique notification id
     * @param title Notification title
     * @param body Notification body text
     * @param style "timer", "metric", or "progress"
     * @param endTimeMillis End time for timer style (epoch millis, countdown target)
     * @param shortCriticalText Short text for status chip on API 35+ (e.g. "5min", "低电量")
     * @param extrasJson JSON string with extras for click intent
     * @param ongoing Whether the notification is ongoing (default true for live updates)
     */
    fun postLiveUpdate(
        id: Int,
        title: String,
        body: String,
        style: String = "timer",
        endTimeMillis: Long = 0L,
        shortCriticalText: String? = null,
        extrasJson: String? = null,
        ongoing: Boolean = true,
        progressMax: Int = 0,
        progressCurrent: Int = 0,
    ): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return false
        }
        val canPromote = canPostPromotedNotifications()

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (!extrasJson.isNullOrBlank()) {
                putExtra(BackgroundService.EXTRA_PUSH_EXTRAS, extrasJson)
            }
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setShowWhen(true)

        // Apply style-specific settings
        when (style) {
            "timer" -> {
                builder.setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText(body)
                )
                if (endTimeMillis > 0) {
                    builder.setWhen(endTimeMillis)
                    builder.setUsesChronometer(true)
                }
            }
            "metric" -> {
                builder.setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText(body)
                )
            }
            "progress" -> {
                builder.setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText(body)
                )
                if (progressMax > 0) {
                    builder.setProgress(progressMax, progressCurrent, false)
                }
            }
            else -> {
                builder.setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText(body)
                )
            }
        }

        var notification = builder.build()

        // Post-build modifications on the notification extras
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val extras = notification.extras
            if (extras != null) {
                // Timer countdown: set chronometer to count down instead of up
                if (style == "timer" && endTimeMillis > 0) {
                    extras.putBoolean("android.chronometerCountDown", true)
                }
            }
        }
        notification = XiaomiLiveUpdateAdapter(context).decorate(
            notification = notification,
            title = title,
            body = body,
            type = typeFromExtras(extrasJson),
            style = style,
            shortText = shortCriticalText,
            progressMax = progressMax,
            progressCurrent = progressCurrent,
            endTimeMillis = endTimeMillis,
        )

        // Apply setShortCriticalText on API 35+ via reflection on the built Notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM
            && !shortCriticalText.isNullOrBlank()
        ) {
            try {
                // setShortCriticalText is a method on Notification.Builder that must be
                // called before build(). Since NotificationCompat.Builder doesn't expose it,
                // we rebuild using the native Notification.Builder on API 35+.
                val nativeBuilder = Notification.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentIntent(pendingIntent)
                    .setOngoing(ongoing)
                    .setAutoCancel(!ongoing)
                    .setCategory(Notification.CATEGORY_EVENT)
                    .setShowWhen(true)

                // Apply style-specific settings on native builder
                when (style) {
                    "timer" -> {
                        nativeBuilder.setStyle(Notification.BigTextStyle().bigText(body))
                    }
                    "progress" -> {
                        nativeBuilder.setStyle(Notification.BigTextStyle().bigText(body))
                        if (progressMax > 0) {
                            nativeBuilder.setProgress(progressMax, progressCurrent, false)
                        }
                    }
                    else -> {
                        nativeBuilder.setStyle(Notification.BigTextStyle().bigText(body))
                    }
                }

                if (endTimeMillis > 0) {
                    nativeBuilder.setWhen(endTimeMillis)
                    nativeBuilder.setUsesChronometer(true)
                    nativeBuilder.setChronometerCountDown(true)
                }

                // setShortCriticalText - available on API 35+
                val setShortCriticalTextMethod = Notification.Builder::class.java.getMethod(
                    "setShortCriticalText", CharSequence::class.java
                )
                setShortCriticalTextMethod.invoke(nativeBuilder, shortCriticalText)

                // setRequestPromotedOngoing - available on API 35+ via native builder
                if (canPromote) {
                    val setRequestPromotedOngoingMethod = Notification.Builder::class.java.getMethod(
                        "setRequestPromotedOngoing", Boolean::class.javaPrimitiveType
                    )
                    setRequestPromotedOngoingMethod.invoke(nativeBuilder, true)
                }

                val rebuiltNotification = XiaomiLiveUpdateAdapter(context).decorate(
                    notification = nativeBuilder.build(),
                    title = title,
                    body = body,
                    type = typeFromExtras(extrasJson),
                    style = style,
                    shortText = shortCriticalText,
                    progressMax = progressMax,
                    progressCurrent = progressCurrent,
                    endTimeMillis = endTimeMillis,
                )
                try {
                    manager.notify(id, rebuiltNotification)
                    return true
                } catch (_: SecurityException) {
                    return false
                }
            } catch (_: Exception) {
                // Fall through to post the compat-built notification
            }
        }

        try {
            manager.notify(id, notification)
            return true
        } catch (_: SecurityException) {
            return false
        }
    }

    /**
     * Cancel a previously posted live update notification.
     */
    fun cancelLiveUpdate(id: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(id)
    }

    private fun typeFromExtras(extrasJson: String?): String {
        if (extrasJson.isNullOrBlank()) return ""
        return try {
            JSONObject(extrasJson).optString("type", "")
        } catch (_: Exception) {
            ""
        }
    }
}
