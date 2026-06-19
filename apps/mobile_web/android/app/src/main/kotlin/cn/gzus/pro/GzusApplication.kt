package cn.gzus.pro

import android.app.Application
import com.tencent.bugly.crashreport.CrashReport
import com.tencent.upgrade.bean.UpgradeConfig
import com.tencent.upgrade.core.UpgradeManager

class GzusApplication : Application() {
    companion object {
        var buglyInitialized = false
            private set
        var shiplyInitialized = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        initBugly()
        initShiply()
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
                isEnableNativeCrashMonitor = false
            }

            CrashReport.initCrashReport(applicationContext, buglyAppId, false, strategy)
            buglyInitialized = true
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun initShiply() {
        try {
            val appInfo = packageManager.getApplicationInfo(packageName, android.content.pm.PackageManager.GET_META_DATA)
            val shiplyAppId = appInfo.metaData.getString("SHIPLY_APP_ID") ?: ""
            val shiplyAppKey = appInfo.metaData.getString("SHIPLY_APP_KEY") ?: ""
            val appChannel = appInfo.metaData.getString("BUGLY_CHANNEL") ?: "gzus_pro"

            if (shiplyAppId.isBlank() || shiplyAppKey.isBlank()) return

            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            val config = UpgradeConfig.Builder()
                .appId(shiplyAppId)
                .appKey(shiplyAppKey)
                .appChannel(appChannel)
                .currentBuildNo(packageInfo.versionCode)
                .useShiplyChannel(true)
                .allowDownloadOverMobile(true)
                .debugMode(BuildConfig.DEBUG)
                .printInternalLog(BuildConfig.DEBUG)
                .monitorLifecycle(true)
                .isMainProcess(true)
                .build()

            UpgradeManager.getInstance().init(applicationContext, config)
            shiplyInitialized = true
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
