package cn.gzus.pro

import android.content.Intent
import android.widget.RemoteViewsService

class BusinessProgressService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return BusinessProgressFactory(applicationContext, intent)
    }
}
