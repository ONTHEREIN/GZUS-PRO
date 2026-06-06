package cn.gzus.pro

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import com.tencent.bugly.crashreport.CrashReport
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val PERMISSIONS_CHANNEL = "cn.gzus.pro/permissions"
    private val BUGLY_CHANNEL = "cn.gzus.pro/bugly"
    private val HOME_WIDGETS_CHANNEL = "cn.gzus.pro/home_widgets"
    private val PUSH_CHANNEL = "cn.gzus.pro/push"
    private var pendingInitialTab: String? = null
    private var pendingWidgetKind: String? = null
    private var homeWidgetsChannel: MethodChannel? = null
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureWidgetLaunch(intent)
        BackgroundService.storePendingOpen(applicationContext, intent?.getStringExtra(BackgroundService.EXTRA_PUSH_EXTRAS))
    }

    override fun onResume() {
        super.onResume()
        getSharedPreferences(BackgroundService.PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putBoolean(BackgroundService.KEY_APP_FOREGROUND, true)
            .apply()
    }

    override fun onPause() {
        getSharedPreferences(BackgroundService.PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putBoolean(BackgroundService.KEY_APP_FOREGROUND, false)
            .apply()
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureWidgetLaunch(intent)
        BackgroundService.storePendingOpen(applicationContext, intent.getStringExtra(BackgroundService.EXTRA_PUSH_EXTRAS))
        notifyWidgetLaunch(clearAfterSend = true)
    }
    
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 权限处理 channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAutoStartPermission" -> {
                    result.success(checkAutoStartPermission())
                }
                "checkBatteryOptimization" -> {
                    result.success(checkBatteryOptimization())
                }
                "checkNotificationPermission" -> {
                    result.success(checkNotificationPermission())
                }
                "openAutoStartSettings" -> {
                    result.success(openAutoStartSettings())
                }
                "openBatteryOptimizationSettings" -> {
                    result.success(openBatteryOptimizationSettings())
                }
                "setHideFromRecents" -> {
                    val hide = call.argument<Boolean>("hide") ?: false
                    setHideFromRecents(hide)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.gzus.pro/background_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    val intent = Intent(this, BackgroundService::class.java).apply {
                        action = BackgroundService.ACTION_START
                        putExtra(BackgroundService.EXTRA_API_BASE_URL, call.argument<String>("apiBaseUrl"))
                        putExtra(BackgroundService.EXTRA_SESSION_ID, call.argument<String>("sessionId"))
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopForegroundService" -> {
                    val intent = Intent(this, BackgroundService::class.java).apply {
                        action = BackgroundService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PUSH_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeNotificationOpen" -> {
                    result.success(BackgroundService.consumePendingOpen(applicationContext))
                }
                else -> result.notImplemented()
            }
        }

        homeWidgetsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOME_WIDGETS_CHANNEL)
        homeWidgetsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    val prefs = getSharedPreferences("gzus_home_widgets", MODE_PRIVATE)
                    prefs.edit()
                        .putString("nextTitle", args["nextTitle"]?.toString() ?: "")
                        .putString("nextMeta", args["nextMeta"]?.toString() ?: "")
                        .putString("nextDescription", args["nextDescription"]?.toString() ?: "")
                        .putString("nextDetail", args["nextDetail"]?.toString() ?: "")
                        .putString("nextClassroom", args["nextClassroom"]?.toString() ?: "")
                        .putString("nextTeacher", args["nextTeacher"]?.toString() ?: "")
                        .putString("nextStatus", args["nextStatus"]?.toString() ?: "")
                        .putString("nextTime", args["nextTime"]?.toString() ?: "")
                        .putString("todayTitle", args["todayTitle"]?.toString() ?: "")
                        .putString("todayMeta", args["todayMeta"]?.toString() ?: "")
                        .putString("todayDescription", args["todayDescription"]?.toString() ?: "")
                        .putString("todayItems", JSONArray(args["todayItems"] as? List<*> ?: emptyList<Any>()).toString())
                        .putString("utilityTitle", args["utilityTitle"]?.toString() ?: "")
                        .putString("utilityMeta", args["utilityMeta"]?.toString() ?: "")
                        .putString("utilityDescription", args["utilityDescription"]?.toString() ?: "")
                        .putString("utilityDetail", args["utilityDetail"]?.toString() ?: "")
                        .putString("utilityColdWater", args["utilityColdWater"]?.toString() ?: "")
                        .putString("utilityHotWater", args["utilityHotWater"]?.toString() ?: "")
                        .putString("utilityElectricity", args["utilityElectricity"]?.toString() ?: "")
                        .putString("utilityRoomInfo", args["utilityRoomInfo"]?.toString() ?: "")
                        .putString("progressTitle", args["progressTitle"]?.toString() ?: "")
                        .putString("progressMeta", args["progressMeta"]?.toString() ?: "")
                        .putString("progressDescription", args["progressDescription"]?.toString() ?: "")
                        .putString("progressDetail", args["progressDetail"]?.toString() ?: "")
                        .putString("todayCoursesJson", args["todayCoursesJson"]?.toString() ?: "[]")
                        .putString("progressItemsJson", args["progressItemsJson"]?.toString() ?: "[]")
                        .apply()
                    HomeWidgetProvider.updateAll(this)
                    result.success(true)
                }
                "consumeInitialTab" -> {
                    val tab = pendingInitialTab
                    pendingInitialTab = null
                    pendingWidgetKind = null
                    result.success(tab)
                }
                else -> result.notImplemented()
            }
        }
        schedulePendingWidgetLaunch()
        
        // Bugly channel
        setupBuglyChannel(flutterEngine)
    }

    private fun captureWidgetLaunch(intent: Intent?) {
        pendingInitialTab = intent?.getStringExtra(HomeWidgetProvider.EXTRA_INITIAL_TAB)
        pendingWidgetKind = intent?.getStringExtra(HomeWidgetProvider.EXTRA_WIDGET_KIND)
    }

    private fun schedulePendingWidgetLaunch() {
        val handler = Handler(Looper.getMainLooper())
        listOf(1000L, 3000L, 6000L).forEachIndexed { index, delay ->
            handler.postDelayed({
                notifyWidgetLaunch(clearAfterSend = index == 2)
            }, delay)
        }
    }

    private fun notifyWidgetLaunch(clearAfterSend: Boolean) {
        val tab = pendingInitialTab ?: return
        val channel = homeWidgetsChannel ?: return
        channel.invokeMethod(
            "launch",
            mapOf(
                "tab" to tab,
                "kind" to (pendingWidgetKind ?: "")
            )
        )
        if (clearAfterSend) {
            pendingInitialTab = null
            pendingWidgetKind = null
        }
    }

    private fun checkAutoStartPermission(): Boolean {
        return try {
            val manufacturer = Build.MANUFACTURER.lowercase()
            when {
                manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                }
                manufacturer.contains("xiaomi") || manufacturer.contains("redmi") -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                }
                manufacturer.contains("oppo") || manufacturer.contains("realme") -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                }
                manufacturer.contains("vivo") -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                }
                else -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                }
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun checkBatteryOptimization(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                pm.isIgnoringBatteryOptimizations(packageName)
            } else {
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun checkNotificationPermission(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val notificationManager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
                notificationManager.areNotificationsEnabled()
            } else {
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun openAutoStartSettings(): Boolean {
        return try {
            val manufacturer = Build.MANUFACTURER.lowercase()
            val intent = when {
                manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.huawei.systemmanager",
                            "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                        )
                    }
                }
                manufacturer.contains("xiaomi") || manufacturer.contains("redmi") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.miui.securitycenter",
                            "com.miui.permcenter.autostart.AutoStartManagementActivity"
                        )
                    }
                }
                manufacturer.contains("oppo") || manufacturer.contains("realme") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.coloros.safecenter",
                            "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                        )
                    }
                }
                manufacturer.contains("vivo") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.vivo.permissionmanager",
                            "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                        )
                    }
                }
                manufacturer.contains("samsung") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.samsung.android.lool",
                            "com.samsung.android.sm.battery.ui.BatteryActivity"
                        )
                    }
                }
                manufacturer.contains("oneplus") -> {
                    Intent().apply {
                        component = ComponentName(
                            "com.oneplus.security",
                            "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                        )
                    }
                }
                else -> {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                }
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val fallback = Intent(Settings.ACTION_SETTINGS)
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallback)
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
            } else {
                Intent(Settings.ACTION_SETTINGS)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val fallback = Intent(Settings.ACTION_SETTINGS)
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallback)
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun setHideFromRecents(hide: Boolean) {
        val flag = 0x80000000.toInt() // FLAG_EXCLUDE_FROM_RECENTS
        if (hide) {
            window.addFlags(flag)
        } else {
            window.clearFlags(flag)
        }
    }
    
    private fun setupBuglyChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BUGLY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    result.success(GzusApplication.buglyInitialized)
                }
                "setUserId" -> {
                    val userId = call.argument<String>("userId")
                    if (userId != null) {
                        CrashReport.setUserId(userId)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "userId is required", null)
                    }
                }
                "setTag" -> {
                    val tagId = call.argument<Int>("tagId")
                    if (tagId != null) {
                        CrashReport.setUserSceneTag(context, tagId)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "tagId is required", null)
                    }
                }
                "setUserData" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<String>("value")
                    if (key != null && value != null) {
                        CrashReport.putUserData(context, key, value)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "key and value are required", null)
                    }
                }
                "reportException" -> {
                    val exception = call.argument<String>("exception")
                    val stackTrace = call.argument<String>("stackTrace")
                    val reason = call.argument<String>("reason")
                    if (exception != null && stackTrace != null) {
                        val throwable = Exception(exception)
                        CrashReport.postCatchedException(throwable)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "exception and stackTrace are required", null)
                    }
                }
                "testCrash" -> {
                    CrashReport.testJavaCrash()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
