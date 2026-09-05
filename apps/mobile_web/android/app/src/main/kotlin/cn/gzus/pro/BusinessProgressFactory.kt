package cn.gzus.pro

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

class BusinessProgressFactory(private val context: Context, private val intent: Intent) : RemoteViewsService.RemoteViewsFactory {

    private var items: List<ProgressItem> = emptyList()

    data class ProgressItem(
        val title: String,
        val status: String,
        val node: String,
        val progress: String,
        val date: String,
        val itemKey: String,
    )

    override fun onCreate() {}
    override fun onDestroy() { items = emptyList() }

    override fun onDataSetChanged() {
        val prefs = context.getSharedPreferences("gzus_home_widgets", Context.MODE_PRIVATE)
        val json = prefs.getString("progressItemsJson", "[]") ?: "[]"
        items = parseItems(json)
    }

    private fun parseItems(json: String): List<ProgressItem> {
        val result = mutableListOf<ProgressItem>()
        try {
            val array = JSONArray(json)
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                result.add(ProgressItem(
                    title = obj.optString("title", ""),
                    status = obj.optString("status", ""),
                    node = obj.optString("node", ""),
                    progress = obj.optString("progress", ""),
                    date = obj.optString("date", ""),
                    itemKey = obj.optString("itemKey", obj.optString("title", ""))
                ))
            }
        } catch (_: Exception) {}
        return result
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews {
        val item = items[position]
        val views = RemoteViews(context.packageName, R.layout.widget_progress_item)
        views.setTextViewText(R.id.item_title, item.title)
        views.setTextViewText(R.id.item_status, item.status)
        // Build info line from node, progress, date
        val infoParts = mutableListOf<String>()
        if (item.node.isNotEmpty()) infoParts.add(item.node)
        if (item.progress.isNotEmpty()) infoParts.add("${item.progress}%")
        if (item.date.isNotEmpty()) infoParts.add(item.date)
        views.setTextViewText(R.id.item_info, infoParts.joinToString(" · "))
        views.setOnClickFillInIntent(
            R.id.progress_item_root,
            HomeWidgetProvider.itemIntent(item.itemKey, null, null, null),
        )
        // Set dot color based on status
        val dotColor = when {
            item.status.contains("待") || item.status.contains("进行") -> 0xFFB3261E.toInt()
            item.status.contains("已") -> 0xFF386A20.toInt()
            else -> 0xFF386A9F.toInt()
        }
        views.setInt(R.id.item_dot, "setBackgroundColor", dotColor)
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}
