package cn.gzus.pro

import android.app.Notification
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import org.json.JSONObject

class XiaomiLiveUpdateAdapter(private val context: Context) {
    data class Capability(
        val supportIsland: Boolean,
        val focusProtocolVersion: Int,
        val hasFocusPermission: Boolean,
    ) {
        val canUseIsland: Boolean
            get() = supportIsland && focusProtocolVersion >= 3 && hasFocusPermission
        val canUseFocus: Boolean
            get() = focusProtocolVersion >= 2 && hasFocusPermission
    }

    fun capability(): Capability {
        return Capability(
            supportIsland = systemBoolean("persist.sys.feature.island", false),
            focusProtocolVersion = runCatching {
                Settings.System.getInt(context.contentResolver, "notification_focus_protocol", 0)
            }.getOrDefault(0),
            hasFocusPermission = hasFocusPermission(),
        )
    }

    fun decorate(
        notification: Notification,
        title: String,
        body: String,
        type: String,
        style: String,
        shortText: String?,
        progressMax: Int,
        progressCurrent: Int,
        endTimeMillis: Long,
    ): Notification {
        val capability = capability()
        if (!capability.canUseIsland && !capability.canUseFocus) return notification

        val params = JSONObject().apply {
            put("version", if (capability.canUseIsland) 3 else 2)
            put("scene", type.ifBlank { "live_update" })
            put("style", style)
            put("title", title)
            put("content", body)
            put("shortText", shortText ?: title)
            if (progressMax > 0) {
                put("progressMax", progressMax)
                put("progressCurrent", progressCurrent.coerceIn(0, progressMax))
            }
            if (endTimeMillis > 0) {
                put("endTime", endTimeMillis)
            }
        }.toString()

        notification.extras.putString("miui.focus.param", params)
        notification.extras.putBoolean("miui.focus.enable", true)
        notification.extras.putInt("miui.focus.protocol", capability.focusProtocolVersion)
        notification.extras.putBoolean("miui.focus.island", capability.canUseIsland)
        return notification
    }

    private fun systemBoolean(key: String, defaultValue: Boolean): Boolean {
        return try {
            val clazz = Class.forName("android.os.SystemProperties")
            val method = clazz.getDeclaredMethod("getBoolean", String::class.java, Boolean::class.javaPrimitiveType)
            method.invoke(null, key, defaultValue) as? Boolean ?: defaultValue
        } catch (_: Exception) {
            defaultValue
        }
    }

    private fun hasFocusPermission(): Boolean {
        return try {
            val uri = Uri.parse("content://miui.statusbar.notification.public")
            val extras = Bundle().apply {
                putString("package", context.packageName)
            }
            val bundle = context.contentResolver.call(uri, "canShowFocus", null, extras)
            bundle?.getBoolean("canShowFocus", false) ?: false
        } catch (_: Exception) {
            false
        }
    }
}
