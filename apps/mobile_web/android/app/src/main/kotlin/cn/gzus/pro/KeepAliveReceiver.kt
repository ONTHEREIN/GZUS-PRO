package cn.gzus.pro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class KeepAliveReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != BackgroundService.ACTION_KEEP_ALIVE) return

        val prefs = context.getSharedPreferences(BackgroundService.PREFS_NAME, Context.MODE_PRIVATE)
        val hasSession = !prefs.getString(BackgroundService.KEY_SESSION_ID, "").isNullOrBlank()
        val hasBaseUrl = !prefs.getString(BackgroundService.KEY_API_BASE_URL, "").isNullOrBlank()

        if (!hasSession || !hasBaseUrl) return

        // Check if BackgroundService is already running by checking if the foreground
        // notification is active. We simply try to start the service — if it's already
        // running, onStartCommand will be called again which is harmless.
        val serviceIntent = Intent(context, BackgroundService::class.java).apply {
            action = BackgroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }

        // Re-schedule the next keep-alive alarm
        BackgroundService.scheduleKeepAlive(context)
    }
}
