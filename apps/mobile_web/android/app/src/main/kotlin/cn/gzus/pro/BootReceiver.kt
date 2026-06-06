package cn.gzus.pro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }
        val prefs = context.getSharedPreferences(BackgroundService.PREFS_NAME, Context.MODE_PRIVATE)
        val hasSession = !prefs.getString(BackgroundService.KEY_SESSION_ID, "").isNullOrBlank()
        val hasBaseUrl = !prefs.getString(BackgroundService.KEY_API_BASE_URL, "").isNullOrBlank()
        if (!hasSession || !hasBaseUrl) return

        val serviceIntent = Intent(context, BackgroundService::class.java).apply {
            action = BackgroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
