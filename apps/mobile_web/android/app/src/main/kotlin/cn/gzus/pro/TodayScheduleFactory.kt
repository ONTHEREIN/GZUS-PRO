package cn.gzus.pro

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

class TodayScheduleFactory(private val context: Context, private val intent: Intent) : RemoteViewsService.RemoteViewsFactory {

    private var items: List<CourseItem> = emptyList()

    data class CourseItem(
        val time: String,
        val name: String,
        val info: String,
        val isOngoing: Boolean,
        val itemKey: String,
        val week: Int,
        val weekday: Int,
        val startSection: Int,
    )

    override fun onCreate() {}
    override fun onDestroy() { items = emptyList() }

    override fun onDataSetChanged() {
        val prefs = context.getSharedPreferences("gzus_home_widgets", Context.MODE_PRIVATE)
        val json = prefs.getString("todayCoursesJson", "[]") ?: "[]"
        items = parseCourses(json)
    }

    private fun parseCourses(json: String): List<CourseItem> {
        val result = mutableListOf<CourseItem>()
        try {
            val array = JSONArray(json)
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                result.add(CourseItem(
                    time = obj.optString("time", ""),
                    name = obj.optString("name", ""),
                    info = obj.optString("info", ""),
                    isOngoing = obj.optBoolean("ongoing", false),
                    itemKey = obj.optString("itemKey", ""),
                    week = obj.optInt("week", 0),
                    weekday = obj.optInt("weekday", 0),
                    startSection = obj.optInt("startSection", 0),
                ))
            }
        } catch (_: Exception) {}
        return result
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews {
        val item = items[position]
        val views = RemoteViews(context.packageName, R.layout.widget_today_item)
        views.setTextViewText(R.id.item_time, item.time)
        views.setTextViewText(R.id.item_name, item.name)
        views.setTextViewText(R.id.item_info, item.info)
        // Set dot color based on ongoing state
        val dotColor = if (item.isOngoing) 0xFFB3261E.toInt() else 0xFF386A9F.toInt()
        views.setInt(R.id.item_dot, "setBackgroundColor", dotColor)
        // Set item name color for ongoing
        if (item.isOngoing) {
            views.setInt(R.id.item_name, "setTextColor", 0xFFB3261E.toInt())
        }
        views.setOnClickFillInIntent(
            R.id.today_item_root,
            HomeWidgetProvider.itemIntent(item.itemKey, item.week.takeIf { it > 0 }, item.weekday, item.startSection),
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}
