package cn.gzus.pro

import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.app.AlarmManager
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.provider.CalendarContract
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.tencent.upgrade.bean.UpgradeStrategy
import com.tencent.upgrade.callback.UpgradeStrategyRequestCallback
import com.tencent.upgrade.core.DefaultUpgradeStrategyRequestCallback
import com.tencent.upgrade.core.UpgradeManager
import com.tencent.upgrade.core.UpgradeReqCallbackForUserManualCheck
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val PERMISSIONS_CHANNEL = "cn.gzus.pro/permissions"
    private val HOME_WIDGETS_CHANNEL = "cn.gzus.pro/home_widgets"
    private val PUSH_CHANNEL = "cn.gzus.pro/push"
    private val LIVE_UPDATE_CHANNEL = "cn.gzus.pro/live_update"
    private val FTP_CHANNEL = "cn.gzus.pro/ftp"
    private val UPGRADE_CHANNEL = "cn.gzus.pro/upgrade"
    private val CALENDAR_CHANNEL = "cn.gzus.pro/calendar"
    private var pendingInitialTab: String? = null
    private var pendingWidgetKind: String? = null
    private var pendingWidgetItemKey: String? = null
    private var pendingWidgetWeek: Int? = null
    private var pendingWidgetWeekday: Int? = null
    private var pendingWidgetStartSection: Int? = null
    private var homeWidgetsChannel: MethodChannel? = null
    private var pendingCalendarResult: MethodChannel.Result? = null
    private var pendingCalendarEvents: List<Map<*, *>>? = null
    
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
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(true)
                }
                "checkExactAlarmPermission" -> {
                    result.success(checkExactAlarmPermission())
                }
                "checkLocationPermission" -> {
                    result.success(checkLocationPermission())
                }
                "requestLocationPermission" -> {
                    requestLocationPermission()
                    result.success(true)
                }
                "openAutoStartSettings" -> {
                    result.success(openAutoStartSettings())
                }
                "openBatteryOptimizationSettings" -> {
                    result.success(openBatteryOptimizationSettings())
                }
                "openExactAlarmSettings" -> {
                    result.success(openExactAlarmSettings())
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.gzus.pro/location").setMethodCallHandler { call, result ->
            when (call.method) {
                "getCoarseLocation" -> {
                    try {
                        val loc = getLastKnownLocation()
                        if (loc != null) {
                            val map = HashMap<String, Double>()
                            map["lat"] = loc.latitude
                            map["lon"] = loc.longitude
                            result.success(map)
                        } else {
                            result.success(null)
                        }
                    } catch (e: SecurityException) {
                        result.error("LOCATION_PERMISSION_DENIED", "定位权限未授予", null)
                    } catch (e: Exception) {
                        result.error("LOCATION_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDAR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "importEvents" -> {
                    try {
                        val events = (call.argument<List<*>>("events") ?: emptyList<Any>())
                            .filterIsInstance<Map<*, *>>()
                        if (events.isEmpty()) {
                            result.success(0)
                            return@setMethodCallHandler
                        }
                        if (hasCalendarPermission()) {
                            insertCalendarEvents(events, result)
                        } else {
                            pendingCalendarResult = result
                            pendingCalendarEvents = events
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    android.Manifest.permission.READ_CALENDAR,
                                    android.Manifest.permission.WRITE_CALENDAR,
                                ),
                                CALENDAR_PERMISSION_REQUEST_CODE,
                            )
                        }
                    } catch (e: Exception) {
                        result.error("CALENDAR_ERROR", e.message ?: "导入日历失败", null)
                    }
                }
                else -> result.notImplemented()
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
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_SERVICE_START_FAILED", e.message, null)
                    }
                }
                "stopForegroundService" -> {
                    val intent = Intent(this, BackgroundService::class.java).apply {
                        action = BackgroundService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                "setAppForeground" -> {
                    val foreground = call.argument<Boolean>("foreground") ?: true
                    getSharedPreferences(BackgroundService.PREFS_NAME, MODE_PRIVATE)
                        .edit()
                        .putBoolean(BackgroundService.KEY_APP_FOREGROUND, foreground)
                        .apply()
                    result.success(true)
                }
                "updateCourseReminders" -> {
                    val coursesJson = call.argument<String>("coursesJson") ?: "[]"
                    val beforeStartMinutes = call.argument<Int>("beforeStartMinutes") ?: 10
                    val beforeEndMinutes = call.argument<Int>("beforeEndMinutes") ?: 5
                    val firstWeekStart = call.argument<String>("firstWeekStart") ?: ""
                    CourseReminderScheduler.saveCourseData(
                        this, coursesJson, beforeStartMinutes, beforeEndMinutes, firstWeekStart
                    )
                    result.success(true)
                }
                "cancelCourseReminders" -> {
                    CourseReminderScheduler(this).cancelAll()
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIVE_UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            val helper = LiveUpdateNotificationHelper(this)
            when (call.method) {
                "postLiveUpdate" -> {
                    try {
                        val id = call.argument<Int>("id") ?: 0
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        val style = call.argument<String>("style") ?: "timer"
                        val endTimeMillis = when (val value = call.argument<Any>("endTimeMillis")) {
                            is Long -> value
                            is Int -> value.toLong()
                            is Number -> value.toLong()
                            else -> 0L
                        }
                        val shortCriticalText = call.argument<String>("shortCriticalText")
                        val extrasJson = call.argument<String>("extras")
                        val ongoing = call.argument<Boolean>("ongoing") ?: (style != "metric")
                        val progressMax = call.argument<Int>("progressMax") ?: 0
                        val progressCurrent = call.argument<Int>("progressCurrent") ?: 0
                        val posted = helper.postLiveUpdate(
                            id = id,
                            title = title,
                            body = body,
                            style = style,
                            endTimeMillis = endTimeMillis,
                            shortCriticalText = shortCriticalText,
                            extrasJson = extrasJson,
                            ongoing = ongoing,
                            progressMax = progressMax,
                            progressCurrent = progressCurrent,
                        )
                        result.success(posted)
                    } catch (e: Exception) {
                        result.error("LIVE_UPDATE_ERROR", e.message, null)
                    }
                }
                "cancelLiveUpdate" -> {
                    try {
                        val id = call.argument<Int>("id") ?: 0
                        helper.cancelLiveUpdate(id)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LIVE_UPDATE_ERROR", e.message, null)
                    }
                }
                "canPostPromotedNotifications" -> {
                    try {
                        val canPost = helper.canPostPromotedNotifications()
                        result.success(canPost)
                    } catch (e: Exception) {
                        result.error("LIVE_UPDATE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        val ftpClient = FtpUploadClient()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FTP_CHANNEL).setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            Thread {
                try {
                    val value = when (call.method) {
                        "testConnection" -> {
                            ftpClient.testConnection(args)
                            true
                        }
                        "listDirectory" -> ftpClient.listDirectory(args)
                        "uploadFile" -> ftpClient.uploadFile(args)
                        "downloadFile" -> ftpClient.downloadFile(args)
                        "disconnect" -> true
                        else -> {
                            runOnUiThread { result.notImplemented() }
                            return@Thread
                        }
                    }
                    runOnUiThread { result.success(value) }
                } catch (e: FtpUploadException) {
                    runOnUiThread { result.error(e.code, e.message, null) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("FTP_ERROR", e.message ?: "FTP 操作失败", null) }
                }
            }.start()
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
                        .putString("weeklyCoursesJson", args["weeklyCoursesJson"]?.toString() ?: "[]")
                        .putString("progressItemsJson", args["progressItemsJson"]?.toString() ?: "[]")
                        .putString("examItemsJson", args["examItemsJson"]?.toString() ?: "[]")
                        .putString("gradeItemsJson", args["gradeItemsJson"]?.toString() ?: "[]")
                        .putString("gradeGpa", args["gradeGpa"]?.toString() ?: "0.00")
                        .putString("gradeAverage", args["gradeAverage"]?.toString() ?: "0.0")
                        .putString("gradeCount", args["gradeCount"]?.toString() ?: "0")
                        .putBoolean("utilityIsBound", args["utilityIsBound"] as? Boolean ?: false)
                        .putBoolean("utilityLowPower", args["utilityLowPower"] as? Boolean ?: false)
                        .apply()
                    val baseUrl = args["widgetApiBaseUrl"]?.toString().orEmpty()
                    val sessionId = args["widgetSessionId"]?.toString().orEmpty()
                    val year = (args["widgetYear"] as? Number)?.toInt() ?: 0
                    val term = (args["widgetTerm"] as? Number)?.toInt() ?: 0
                    val week = (args["widgetCurrentWeek"] as? Number)?.toInt() ?: 0
                    if (baseUrl.isNotBlank() && sessionId.isNotBlank()) {
                        try {
                            WidgetRefreshScheduler.configure(this, baseUrl, sessionId, year, term, week)
                        } catch (error: IllegalArgumentException) {
                            result.error("WIDGET_REFRESH_CONFIG_INVALID", error.message, null)
                            return@setMethodCallHandler
                        }
                    }
                    HomeWidgetProvider.updateAll(this)
                    result.success(true)
                }
                "replaceRefreshSession" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    try {
                        WidgetRefreshScheduler.replaceSession(
                            this,
                            args["widgetApiBaseUrl"]?.toString().orEmpty(),
                            args["widgetSessionId"]?.toString().orEmpty(),
                        )
                        result.success(true)
                    } catch (error: IllegalArgumentException) {
                        result.error("WIDGET_REFRESH_CONFIG_INVALID", error.message, null)
                    }
                }
                "clearRefreshConfiguration" -> {
                    WidgetRefreshScheduler.clear(this)
                    getSharedPreferences("gzus_home_widgets", MODE_PRIVATE).edit().clear().apply()
                    HomeWidgetProvider.updateAll(this)
                    result.success(true)
                }
                "consumeLaunchTarget" -> {
                    val target = pendingInitialTab?.let {
                        mapOf(
                            "tab" to it,
                            "kind" to (pendingWidgetKind ?: ""),
                            "itemKey" to (pendingWidgetItemKey ?: ""),
                            "week" to pendingWidgetWeek,
                            "weekday" to pendingWidgetWeekday,
                            "startSection" to pendingWidgetStartSection,
                        )
                    }
                    pendingInitialTab = null
                    pendingWidgetKind = null
                    pendingWidgetItemKey = null
                    pendingWidgetWeek = null
                    pendingWidgetWeekday = null
                    pendingWidgetStartSection = null
                    result.success(target)
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
        
        setupUpgradeChannel(flutterEngine)
    }

    private fun captureWidgetLaunch(intent: Intent?) {
        pendingInitialTab = intent?.getStringExtra(HomeWidgetProvider.EXTRA_INITIAL_TAB)
        pendingWidgetKind = intent?.getStringExtra(HomeWidgetProvider.EXTRA_WIDGET_KIND)
        pendingWidgetItemKey = intent?.getStringExtra("itemKey")
        pendingWidgetWeek = intent?.getIntExtra("week", 0)?.takeIf { it > 0 }
        pendingWidgetWeekday = intent?.getIntExtra("weekday", 0)?.takeIf { it > 0 }
        pendingWidgetStartSection = intent?.getIntExtra("startSection", 0)?.takeIf { it > 0 }
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
                "kind" to (pendingWidgetKind ?: ""),
                "itemKey" to (pendingWidgetItemKey ?: ""),
                "week" to pendingWidgetWeek,
                "weekday" to pendingWidgetWeekday,
                "startSection" to pendingWidgetStartSection,
            )
        )
        if (clearAfterSend) {
            pendingInitialTab = null
            pendingWidgetKind = null
            pendingWidgetItemKey = null
            pendingWidgetWeek = null
            pendingWidgetWeekday = null
            pendingWidgetStartSection = null
        }
    }

    /**
     * Best-effort proxy for auto-start permission.
     *
     * On most Chinese ROMs (Xiaomi, Huawei, OPPO, VIVO, etc.) the true
     * auto-start permission is governed by a private vendor API that has no
     * public SDK equivalent.  In practice the battery-optimisation bypass is
     * the strongest signal we can query; apps that are allowed to ignore
     * battery optimisations are also much more likely to survive process
     * death and receive broadcasts.
     *
     * If a vendor-specific check becomes available in the future, update here.
     */
    private fun checkAutoStartPermission(): Boolean {
        return checkBatteryOptimization()
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

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun checkExactAlarmPermission(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val alarmManager = getSystemService(ALARM_SERVICE) as AlarmManager
                alarmManager.canScheduleExactAlarms()
            } else {
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun checkLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocationPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(android.Manifest.permission.ACCESS_COARSE_LOCATION),
            LOCATION_PERMISSION_REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == CALENDAR_PERMISSION_REQUEST_CODE) {
            val granted =
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            val events = pendingCalendarEvents
            val pending = pendingCalendarResult
            pendingCalendarEvents = null
            pendingCalendarResult = null
            if (granted && events != null && pending != null) {
                insertCalendarEvents(events, pending)
            } else {
                pending?.error("CALENDAR_PERMISSION_DENIED", "未授予日历权限，无法导入", null)
            }
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun hasCalendarPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.WRITE_CALENDAR
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun insertCalendarEvents(
        events: List<Map<*, *>>,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                val calendarId = writableCalendarId()
                if (calendarId == null) {
                    runOnUiThread {
                        result.error("NO_CALENDAR", "设备上没有可写入的系统日历", null)
                    }
                    return@Thread
                }
                var added = 0
                var updated = 0
                var skipped = 0
                for (raw in events) {
                    val title = raw["title"] as? String
                    val sourceId = raw["sourceId"] as? String
                    val start = (raw["startMillis"] as? Number)?.toLong()
                    val end = (raw["endMillis"] as? Number)?.toLong()
                    if (title.isNullOrEmpty() || sourceId.isNullOrEmpty() || start == null || end == null) {
                        skipped++
                        continue
                    }
                    val marker = "OneGZUS-ID:$sourceId"
                    val description = listOfNotNull(
                        raw["description"]?.toString()?.takeIf { it.isNotEmpty() }, marker
                    ).joinToString("\n\n")
                    val values = ContentValues().apply {
                        put(CalendarContract.Events.CALENDAR_ID, calendarId)
                        put(CalendarContract.Events.TITLE, title)
                        put(CalendarContract.Events.DTSTART, start)
                        put(CalendarContract.Events.DTEND, end)
                        put(
                            CalendarContract.Events.EVENT_TIMEZONE,
                            java.util.TimeZone.getDefault().id,
                        )
                        put(
                            CalendarContract.Events.EVENT_END_TIMEZONE,
                            java.util.TimeZone.getDefault().id,
                        )
                        put(CalendarContract.Events.ALL_DAY, 0)
                        raw["location"]?.toString()?.takeIf { it.isNotEmpty() }?.let {
                            put(CalendarContract.Events.EVENT_LOCATION, it)
                        }
                        put(CalendarContract.Events.DESCRIPTION, description)
                    }
                    val existingId = contentResolver.query(
                        CalendarContract.Events.CONTENT_URI,
                        arrayOf(CalendarContract.Events._ID, CalendarContract.Events.DESCRIPTION),
                        "${CalendarContract.Events.CALENDAR_ID}=?",
                        arrayOf(calendarId.toString()),
                        null,
                    )?.use { cursor ->
                        val idIndex = cursor.getColumnIndexOrThrow(CalendarContract.Events._ID)
                        val descriptionIndex = cursor.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)
                        var found: Long? = null
                        while (cursor.moveToNext()) {
                            if (cursor.getString(descriptionIndex)?.contains(marker) == true) {
                                found = cursor.getLong(idIndex)
                                break
                            }
                        }
                        found
                    }
                    if (existingId != null) {
                        contentResolver.update(
                            CalendarContract.Events.CONTENT_URI,
                            values,
                            "${CalendarContract.Events._ID}=?",
                            arrayOf(existingId.toString()),
                        )
                        updated++
                    } else if (contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) != null) {
                        added++
                    } else {
                        skipped++
                    }
                }
                val resultMap = mapOf("added" to added, "updated" to updated, "skipped" to skipped)
                runOnUiThread {
                    if (added + updated + skipped > 0) {
                        result.success(resultMap)
                    } else {
                        result.error("CALENDAR_INSERT_FAILED", "未能写入系统日历", null)
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("CALENDAR_ERROR", e.message ?: "导入日历失败", null)
                }
            }
        }.start()
    }

    private fun writableCalendarId(): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )
        var selected: Long? = null
        var writable: Long? = null
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID)
            val levelIndex = cursor.getColumnIndexOrThrow(
                CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
            )
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                if (selected == null) selected = id
                if (cursor.getInt(levelIndex) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR
                    && writable == null
                ) {
                    writable = id
                }
            }
        }
        return writable ?: selected
    }

    private fun getLastKnownLocation(): android.location.Location? {
        if (!checkLocationPermission()) return null
        val locationManager = getSystemService(LOCATION_SERVICE) as LocationManager
        val providers = listOf(
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        for (provider in providers) {
            if (!locationManager.isProviderEnabled(provider)) continue
            try {
                val loc = locationManager.getLastKnownLocation(provider)
                if (loc != null) return loc
            } catch (_: Exception) { }
        }
        return null
    }

    companion object {
        private const val LOCATION_PERMISSION_REQUEST_CODE = 1001
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002
        private const val CALENDAR_PERMISSION_REQUEST_CODE = 1003
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

    private fun openExactAlarmSettings(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                    data = Uri.parse("package:$packageName")
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
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
    
    private fun setupUpgradeChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPGRADE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkUpgrade" -> {
                    if (!UpgradeManager.getInstance().hasInitialedOrNot()) {
                        result.error("SHIPLY_NOT_INITIALIZED", "Shiply SDK is not initialized", null)
                        return@setMethodCallHandler
                    }
                    val isManual = call.argument<Boolean>("isManual") ?: false
                    val uiCallback = if (isManual) {
                        UpgradeReqCallbackForUserManualCheck()
                    } else {
                        DefaultUpgradeStrategyRequestCallback()
                    }
                    val callback = object : UpgradeStrategyRequestCallback {
                        override fun onReceiveStrategy(strategy: UpgradeStrategy) {
                            uiCallback.onReceiveStrategy(strategy)
                            runOnUiThread { result.success(upgradeStrategyToMap(strategy, hasUpdate = true)) }
                        }

                        override fun onFail(code: Int, message: String?) {
                            uiCallback.onFail(code, message)
                            runOnUiThread {
                                result.error("SHIPLY_CHECK_FAILED", message ?: "Shiply upgrade check failed", code)
                            }
                        }

                        override fun onReceivedNoStrategy() {
                            uiCallback.onReceivedNoStrategy()
                            runOnUiThread { result.success(mapOf("hasUpdate" to false)) }
                        }
                    }
                    UpgradeManager.getInstance().checkUpgrade(isManual, emptyMap(), callback)
                }
                "getUpgradeStrategy" -> {
                    if (!UpgradeManager.getInstance().hasInitialedOrNot()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val strategy = UpgradeManager.getInstance().cachedStrategy
                        ?: UpgradeManager.getInstance().reloadCacheStrategyFromDisk()
                    result.success(strategy?.let { upgradeStrategyToMap(it, hasUpdate = hasUsableUpgrade(it)) })
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasUsableUpgrade(strategy: UpgradeStrategy): Boolean {
        return try {
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            strategy.isLaterThan(packageInfo.versionCode, packageInfo.versionCode, packageInfo.versionName ?: "")
        } catch (_: Exception) {
            strategy.apkBasicInfo != null
        }
    }

    private fun upgradeStrategyToMap(strategy: UpgradeStrategy, hasUpdate: Boolean): Map<String, Any?> {
        val apkInfo = strategy.apkBasicInfo
        return mapOf(
            "hasUpdate" to hasUpdate,
            "title" to strategy.title,
            "newFeature" to strategy.newFeature,
            "h5Url" to strategy.h5Url,
            "remindType" to strategy.remindType,
            "updateStrategy" to strategy.updateStrategy,
            "publishTime" to strategy.publishTime,
            "updateTime" to strategy.updateTime,
            "versionName" to apkInfo?.versionName,
            "versionCode" to apkInfo?.versionCode,
            "buildNo" to apkInfo?.buildNo,
            "downloadUrl" to apkInfo?.downloadUrl,
            "apkSize" to apkInfo?.apkSize,
            "apkName" to apkInfo?.apkName,
        )
    }
}
