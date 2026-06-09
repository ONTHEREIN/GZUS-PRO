package cn.gzus.pro

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray

open class HomeWidgetProvider : AppWidgetProvider() {
    open val kind: String = "next"

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        appWidgetIds.forEach {
            try {
                updateWidget(context, appWidgetManager, it, kind)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    companion object {
        private const val PREFS = "gzus_home_widgets"
        const val EXTRA_INITIAL_TAB = "initialTab"
        const val EXTRA_WIDGET_KIND = "widgetKind"

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val providers = listOf(
                NextClassWidgetProvider::class.java to "next",
                TodayScheduleWidgetProvider::class.java to "today",
                UtilitiesWidgetProvider::class.java to "utilities",
                BusinessProgressWidgetProvider::class.java to "progress"
            )
            providers.forEach { (provider, kind) ->
                val ids = manager.getAppWidgetIds(ComponentName(context, provider))
                ids.forEach { updateWidget(context, manager, it, kind) }
            }
        }

        fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            kind: String
        ) {
            try {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

                when (kind) {
                    "utilities" -> updateUtilitiesWidget(context, manager, widgetId, prefs)
                    "next" -> {
                        val data = widgetData(prefs, kind)
                        updateNextClassWidget(context, manager, widgetId, prefs, data)
                    }
                    "today" -> updateTodayWidget(context, manager, widgetId, prefs)
                    "progress" -> updateProgressWidget(context, manager, widgetId, prefs)
                    else -> {
                        val data = widgetData(prefs, kind)
                        updateGenericWidget(context, manager, widgetId, data, kind)
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        private fun updateNextClassWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences,
            data: WidgetData
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_next_class)

            views.setImageViewResource(R.id.widget_icon, R.drawable.widget_icon_next)
            views.setTextViewText(R.id.widget_header_title, data.headerTitle)
            views.setTextViewText(R.id.widget_badge, data.badge)
            views.setTextViewText(R.id.widget_course_name, data.title)
            views.setTextViewText(R.id.widget_time, data.meta)
            views.setTextViewText(R.id.widget_location, data.classroom)
            views.setTextViewText(R.id.widget_teacher, data.teacher)
            views.setInt(R.id.widget_content_block, "setBackgroundResource", R.drawable.widget_content_block_background)

            if (data.classroom.isNullOrBlank()) {
                views.setViewVisibility(R.id.widget_location_row, View.GONE)
            } else {
                views.setViewVisibility(R.id.widget_location_row, View.VISIBLE)
            }

            if (data.teacher.isNullOrBlank()) {
                views.setViewVisibility(R.id.widget_teacher_row, View.GONE)
            } else {
                views.setViewVisibility(R.id.widget_teacher_row, View.VISIBLE)
            }

            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, "next"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun updateGenericWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            data: WidgetData,
            kind: String
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_home_card)

            val iconRes = when (kind) {
                "today" -> R.drawable.widget_icon_today
                "progress" -> R.drawable.widget_icon_progress
                else -> R.drawable.widget_icon_next
            }
            views.setImageViewResource(R.id.widget_icon, iconRes)
            views.setTextViewText(R.id.widget_header_title, data.headerTitle)
            views.setTextViewText(R.id.widget_badge, data.badge)
            views.setTextViewText(R.id.widget_content_title, data.title)
            views.setTextViewText(R.id.widget_meta, data.meta)
            views.setTextViewText(R.id.widget_detail, data.detail)
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, kind))
            manager.updateAppWidget(widgetId, views)
        }

        private fun updateTodayWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_today_schedule)
            val data = widgetData(prefs, "today")

            views.setImageViewResource(R.id.widget_icon, R.drawable.widget_icon_today)
            views.setTextViewText(R.id.widget_header_title, data.headerTitle)
            views.setTextViewText(R.id.widget_badge, data.badge)
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, "today"))

            // Bind ListView with RemoteAdapter
            val listIntent = Intent(context, TodayScheduleService::class.java)
            listIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            listIntent.data = Uri.parse(listIntent.toUri(Intent.URI_INTENT_SCHEME))
            views.setRemoteAdapter(R.id.widget_list, listIntent)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            // Show/hide empty state based on whether there are courses
            val coursesJson = prefs.getString("todayCoursesJson", "[]") ?: "[]"
            val hasCourses = try {
                JSONArray(coursesJson).length() > 0
            } catch (_: Exception) { false }
            views.setViewVisibility(R.id.widget_empty, if (hasCourses) android.view.View.GONE else android.view.View.VISIBLE)
            views.setViewVisibility(R.id.widget_list, if (hasCourses) android.view.View.VISIBLE else android.view.View.GONE)

            manager.updateAppWidget(widgetId, views)
        }

        private fun updateProgressWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_progress)
            val data = widgetData(prefs, "progress")

            views.setImageViewResource(R.id.widget_icon, R.drawable.widget_icon_progress)
            views.setTextViewText(R.id.widget_header_title, data.headerTitle)
            views.setTextViewText(R.id.widget_badge, data.badge)
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, "progress"))

            // Bind ListView with RemoteAdapter
            val listIntent = Intent(context, BusinessProgressService::class.java)
            listIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            listIntent.data = Uri.parse(listIntent.toUri(Intent.URI_INTENT_SCHEME))
            views.setRemoteAdapter(R.id.widget_list, listIntent)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            // Show/hide empty state based on whether there are progress items
            val progressJson = prefs.getString("progressItemsJson", "[]") ?: "[]"
            val hasItems = try {
                JSONArray(progressJson).length() > 0
            } catch (_: Exception) { false }
            views.setViewVisibility(R.id.widget_empty, if (hasItems) android.view.View.GONE else android.view.View.VISIBLE)
            views.setViewVisibility(R.id.widget_list, if (hasItems) android.view.View.VISIBLE else android.view.View.GONE)

            manager.updateAppWidget(widgetId, views)
        }

        private fun updateUtilitiesWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_utilities)

            views.setImageViewResource(R.id.widget_icon, R.drawable.widget_icon_utilities)
            views.setTextViewText(R.id.widget_header_title, "生活缴费")
            views.setTextViewText(R.id.widget_badge, "生活缴费")
            views.setTextViewText(R.id.widget_cold_water, prefText(prefs, "utilityColdWater", "-"))
            views.setTextViewText(R.id.widget_hot_water, prefText(prefs, "utilityHotWater", "-"))
            views.setTextViewText(R.id.widget_electricity, prefText(prefs, "utilityElectricity", "-"))
            views.setTextViewText(R.id.widget_room_info, prefText(prefs, "utilityRoomInfo", ""))
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, "ecard", "utilities"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun widgetData(prefs: android.content.SharedPreferences, kind: String): WidgetData {
            return when (kind) {
                "today" -> WidgetData(
                    headerTitle = "今日课表",
                    badge = "今日课表",
                    title = prefText(prefs, "todayTitle", "今日课表"),
                    meta = prefText(prefs, "todayMeta", "课程提醒"),
                    detail = readList(prefs.getString("todayItems", "[]")).joinToString("\n").ifBlank { "暂无课程" },
                    tab = "schedule"
                )
                "utilities" -> WidgetData(
                    headerTitle = "生活缴费",
                    badge = "生活缴费",
                    title = prefText(prefs, "utilityTitle", "水电费余额"),
                    meta = prefText(prefs, "utilityMeta", "暂无数据"),
                    detail = prefText(prefs, "utilityDetail", "点击查看生活缴费"),
                    tab = "ecard"
                )
                "progress" -> WidgetData(
                    headerTitle = "办事大厅",
                    badge = "办事大厅",
                    title = prefText(prefs, "progressTitle", "业务进度"),
                    meta = prefText(prefs, "progressMeta", "暂无业务进度"),
                    detail = prefText(prefs, "progressDetail", "点击查看办事大厅"),
                    tab = "business"
                )
                else -> WidgetData(
                    headerTitle = "下一节课",
                    badge = "下一节课",
                    title = prefText(prefs, "nextTitle", "下一节课"),
                    meta = prefText(prefs, "nextTime", "暂无数据"),
                    detail = prefText(prefs, "nextDetail", "点击查看课表"),
                    tab = "schedule",
                    classroom = prefs.getString("nextClassroom", null),
                    teacher = prefs.getString("nextTeacher", null)
                )
            }
        }

        private fun prefText(
            prefs: android.content.SharedPreferences,
            key: String,
            fallback: String
        ): String {
            val value = prefs.getString(key, null)
            return if (value.isNullOrBlank()) fallback else value
        }

        private fun readList(value: String?): List<String> {
            return try {
                val array = JSONArray(value ?: "[]")
                List(array.length()) { index -> array.optString(index) }
                    .filter { it.isNotBlank() }
            } catch (_: Exception) {
                emptyList()
            }
        }

        private fun openAppIntent(context: Context, tab: String, kind: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_INITIAL_TAB, tab)
                putExtra(EXTRA_WIDGET_KIND, kind)
            }
            return PendingIntent.getActivity(
                context,
                kind.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }
}

data class WidgetData(
    val headerTitle: String,
    val badge: String,
    val title: String,
    val meta: String,
    val detail: String,
    val tab: String,
    val classroom: String? = null,
    val teacher: String? = null
)

class NextClassWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "next"
}

class TodayScheduleWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "today"
}

class UtilitiesWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "utilities"
}

class BusinessProgressWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "progress"
}
