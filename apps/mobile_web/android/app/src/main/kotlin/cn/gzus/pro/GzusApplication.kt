package cn.gzus.pro

import android.app.Application
import com.tencent.upgrade.bean.UpgradeConfig
import com.tencent.upgrade.core.UpgradeManager

class GzusApplication : Application() {
    companion object {
        var shiplyInitialized = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        initShiply()
    }

    private fun initShiply() {
        try {
            val appInfo = packageManager.getApplicationInfo(packageName, android.content.pm.PackageManager.GET_META_DATA)
            val shiplyAppId = appInfo.metaData.getString("SHIPLY_APP_ID") ?: ""
            val shiplyAppKey = appInfo.metaData.getString("SHIPLY_APP_KEY") ?: ""
            val appChannel = "gzus_pro"

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
