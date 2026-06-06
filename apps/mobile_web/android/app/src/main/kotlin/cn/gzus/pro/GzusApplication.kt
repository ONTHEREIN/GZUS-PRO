package cn.gzus.pro

import android.app.Application
import com.tencent.bugly.crashreport.CrashReport

class GzusApplication : Application() {
    companion object {
        var buglyInitialized = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        initBugly()
    }

    private fun initBugly() {
        try {
            val appInfo = packageManager.getApplicationInfo(packageName, android.content.pm.PackageManager.GET_META_DATA)
            val buglyAppId = appInfo.metaData.getString("BUGLY_APPID") ?: ""
            val buglyChannel = appInfo.metaData.getString("BUGLY_CHANNEL") ?: "gzus_pro"

            val strategy = CrashReport.UserStrategy(this).apply {
                appChannel = buglyChannel
                appVersion = packageManager.getPackageInfo(packageName, 0).versionName
                isEnableANRCrashMonitor = true
                isEnableNativeCrashMonitor = true
            }

            CrashReport.initCrashReport(applicationContext, buglyAppId, false, strategy)
            buglyInitialized = true
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
