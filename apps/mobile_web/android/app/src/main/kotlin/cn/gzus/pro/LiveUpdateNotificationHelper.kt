package cn.gzus.pro

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

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
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = CHANNEL_DESCRIPTION
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /** 返回 Android 实况通知推广资格的三态结果。 */
    fun promotedNotificationStatus(): String {
        if (Build.VERSION.SDK_INT < 36) return "unsupported"
        val notifications = NotificationManagerCompat.from(context)
        if (!notifications.areNotificationsEnabled()) return "authorization_required"
        return if (notifications.canPostPromotedNotifications()) {
            "available"
        } else {
            "authorization_required"
        }
    }

    /** 使用系统标准通知样式发布或更新一条实况通知。 */
    fun postLiveUpdate(payload: LiveUpdatePayload): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false

        val style = payload.renderedStyle
        val safeProgressMax = payload.progressMax.coerceAtLeast(0)
        val safeProgressCurrent = payload.progressCurrent.coerceIn(0, safeProgressMax)
        val showProgress = style == "progress" &&
            safeProgressMax > 0 &&
            safeProgressCurrent < safeProgressMax
        val detailText = LiveUpdateTextFormatter.detail(payload)
        val requestsPromotion = payload.ongoing && isLiveUpdateStyle(style)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(payload.title)
            .setContentText(LiveUpdateTextFormatter.summary(payload))
            .setSmallIcon(iconForType(payload.type))
            .setColor(eventColor(payload.type))
            .setContentIntent(pendingIntent(payload))
            .setOngoing(payload.ongoing)
            .setAutoCancel(!payload.ongoing)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setShowWhen(true)
            .setOnlyAlertOnce(true)
            .setRequestPromotedOngoing(requestsPromotion)

        val primaryValue = LiveUpdateTextFormatter.primaryValue(payload)
        if (!primaryValue.isNullOrBlank()) builder.setContentInfo(primaryValue)
        val subText = subText(payload)
        if (!subText.isNullOrBlank()) builder.setSubText(subText)
        if (!payload.shortCriticalText.isNullOrBlank()) {
            builder.setShortCriticalText(payload.shortCriticalText)
        }

        val timeoutMillis = LiveUpdateTextFormatter.timeoutMillis(
            payload.endTimeMillis,
            System.currentTimeMillis(),
        )
        if (timeoutMillis > 0L) builder.setTimeoutAfter(timeoutMillis)

        when (style) {
            "timer" -> {
                builder.setStyle(NotificationCompat.BigTextStyle().bigText(detailText))
                if (payload.endTimeMillis > 0L) {
                    builder.setWhen(payload.endTimeMillis)
                    builder.setUsesChronometer(true)
                    builder.setChronometerCountDown(true)
                }
            }
            "progress" -> {
                if (Build.VERSION.SDK_INT >= 36 && showProgress) {
                    builder.setStyle(
                        NotificationCompat.ProgressStyle()
                            .setProgress(safeProgressCurrent)
                            .setStyledByProgress(true),
                    )
                } else {
                    builder.setStyle(NotificationCompat.BigTextStyle().bigText(detailText))
                    if (showProgress) {
                        builder.setProgress(safeProgressMax, safeProgressCurrent, false)
                    }
                }
            }
            "metric" -> builder.setStyle(NotificationCompat.BigTextStyle().bigText(detailText))
            else -> builder.setStyle(NotificationCompat.BigTextStyle().bigText(detailText))
        }

        val notification = XiaomiLiveUpdateAdapter(context).decorate(
            notification = builder.build(),
            title = payload.title,
            body = detailText,
            type = payload.type,
            style = style,
            shortText = payload.shortCriticalText,
            progressMax = if (showProgress) safeProgressMax else 0,
            progressCurrent = if (showProgress) safeProgressCurrent else 0,
            endTimeMillis = payload.endTimeMillis,
        )

        return try {
            manager.notify(payload.id, notification)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun cancelLiveUpdate(id: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(id)
    }

    private fun pendingIntent(payload: LiveUpdatePayload): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(BackgroundService.EXTRA_PUSH_EXTRAS, payload.extrasJson)
        }
        return PendingIntent.getActivity(
            context,
            payload.id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun subText(payload: LiveUpdatePayload): String? {
        return when (payload.type) {
            "course_reminder", "exam_reminder" -> payload.location
            "grade_update" -> payload.courseName
            "ecard_reminder" -> payload.utilityPrimaryLabel
            else -> null
        }
    }

    private fun eventColor(type: String): Int {
        return when (type) {
            "exam_reminder", "attendance_update" -> Color.rgb(234, 88, 12)
            "ecard_reminder" -> Color.rgb(14, 165, 233)
            "grade_update" -> Color.rgb(5, 150, 105)
            "business_reminder", "business_update" -> Color.rgb(124, 58, 237)
            else -> Color.rgb(37, 99, 235)
        }
    }

    private fun iconForType(type: String): Int {
        return when (type) {
            "course_reminder" -> R.drawable.ic_stat_course
            "exam_reminder" -> R.drawable.ic_stat_exam
            "grade_update" -> R.drawable.ic_stat_grade
            "ecard_reminder" -> R.drawable.ic_stat_ecard
            "attendance_update" -> R.drawable.ic_stat_attendance
            "business_reminder", "business_update" -> R.drawable.ic_stat_business
            "new_notice" -> R.drawable.ic_stat_notice
            else -> R.drawable.ic_stat_live_update
        }
    }

    private fun isLiveUpdateStyle(style: String): Boolean {
        return style == "timer" || style == "metric" || style == "progress"
    }
}
