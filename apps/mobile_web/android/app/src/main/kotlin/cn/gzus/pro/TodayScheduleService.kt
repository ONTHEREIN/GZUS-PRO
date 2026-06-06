package cn.gzus.pro

import android.content.Intent
import android.widget.RemoteViewsService

class TodayScheduleService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return TodayScheduleFactory(applicationContext, intent)
    }
}
