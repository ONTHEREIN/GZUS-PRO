package cn.gzus.pro

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import java.util.Calendar

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

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateWidget(context, appWidgetManager, appWidgetId, kind)
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
                ExamCountdownWidgetProvider::class.java to "exams",
                GradesWidgetProvider::class.java to "grades",
                UtilitiesWidgetProvider::class.java to "utilities",
                BusinessProgressWidgetProvider::class.java to "progress",
                WeeklyScheduleWidgetProvider::class.java to "weekly"
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
                if (isSmallWidget(manager, widgetId) && kind != "weekly") {
                    updateGenericWidget(context, manager, widgetId, widgetData(prefs, kind), kind)
                    return
                }

                when (kind) {
                    "utilities" -> updateUtilitiesWidget(context, manager, widgetId, prefs)
                    "next" -> {
                        val data = widgetData(prefs, kind)
                        updateNextClassWidget(context, manager, widgetId, prefs, data)
                    }
                    "today" -> updateTodayWidget(context, manager, widgetId, prefs)
                    "exams" -> updateExamsWidget(context, manager, widgetId, prefs)
                    "grades" -> updateGradesWidget(context, manager, widgetId, prefs)
                    "progress" -> updateProgressWidget(context, manager, widgetId, prefs)
                    "weekly" -> updateWeeklyScheduleWidget(context, manager, widgetId, prefs)
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
            views.setTextViewText(R.id.widget_course_name, data.title)
            views.setTextViewText(R.id.widget_time, data.meta)
            views.setTextViewText(R.id.widget_location, data.classroom)
            views.setTextViewText(R.id.widget_teacher, data.teacher)

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

        private fun isSmallWidget(manager: AppWidgetManager, widgetId: Int): Boolean {
            val options = manager.getAppWidgetOptions(widgetId)
            return options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) < 180 &&
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) < 180
        }

        private fun updateGenericWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            data: WidgetData,
            kind: String
        ) {
            val options = manager.getAppWidgetOptions(widgetId)
            val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
            val layout = if (minWidth < 180 && minHeight < 180) {
                R.layout.widget_home_card_small
            } else {
                R.layout.widget_home_card
            }
            val views = RemoteViews(context.packageName, layout)

            val iconRes = when (kind) {
                "today" -> R.drawable.widget_icon_today
                "progress" -> R.drawable.widget_icon_progress
                "exams" -> R.drawable.widget_icon_next
                "grades" -> R.drawable.widget_icon_progress
                else -> R.drawable.widget_icon_next
            }
            views.setImageViewResource(R.id.widget_icon, iconRes)
            views.setTextViewText(R.id.widget_header_title, data.headerTitle)
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
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, "today"))

            // Bind ListView with RemoteAdapter
            val listIntent = Intent(context, TodayScheduleService::class.java)
            listIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            listIntent.data = Uri.parse(listIntent.toUri(Intent.URI_INTENT_SCHEME))
            views.setRemoteAdapter(R.id.widget_list, listIntent)
            views.setPendingIntentTemplate(R.id.widget_list, openAppIntent(context, "schedule", "today"))
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
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, data.tab, "progress"))

            // Bind ListView with RemoteAdapter
            val listIntent = Intent(context, BusinessProgressService::class.java)
            listIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            listIntent.data = Uri.parse(listIntent.toUri(Intent.URI_INTENT_SCHEME))
            views.setRemoteAdapter(R.id.widget_list, listIntent)
            views.setPendingIntentTemplate(R.id.widget_list, openAppIntent(context, "business", "progress"))
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
            views.setTextViewText(R.id.widget_cold_water, prefText(prefs, "utilityColdWater", "-"))
            views.setTextViewText(R.id.widget_hot_water, prefText(prefs, "utilityHotWater", "-"))
            views.setTextViewText(R.id.widget_electricity, prefText(prefs, "utilityElectricity", "-"))
            views.setTextViewText(R.id.widget_room_info, prefText(prefs, "utilityRoomInfo", ""))
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, "ecard", "utilities"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun updateWeeklyScheduleWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_weekly_schedule)
            views.setImageViewResource(R.id.widget_icon, R.drawable.widget_icon_today)
            views.setTextViewText(R.id.widget_header_title, "本周课表")
            val dayNames = listOf("一", "二", "三", "四", "五", "六", "日")
            val courses = JSONArray(prefs.getString("weeklyCoursesJson", "[]") ?: "[]")
            val dayIds = intArrayOf(
                R.id.weekly_day_1, R.id.weekly_day_2, R.id.weekly_day_3,
                R.id.weekly_day_4, R.id.weekly_day_5, R.id.weekly_day_6, R.id.weekly_day_7,
            )
            val courseIds = arrayOf(
                intArrayOf(R.id.weekly_course_1_1, R.id.weekly_course_1_2, R.id.weekly_course_1_3, R.id.weekly_course_1_4, R.id.weekly_course_1_5, R.id.weekly_course_1_6, R.id.weekly_course_1_7, R.id.weekly_course_1_8),
                intArrayOf(R.id.weekly_course_2_1, R.id.weekly_course_2_2, R.id.weekly_course_2_3, R.id.weekly_course_2_4, R.id.weekly_course_2_5, R.id.weekly_course_2_6, R.id.weekly_course_2_7, R.id.weekly_course_2_8),
                intArrayOf(R.id.weekly_course_3_1, R.id.weekly_course_3_2, R.id.weekly_course_3_3, R.id.weekly_course_3_4, R.id.weekly_course_3_5, R.id.weekly_course_3_6, R.id.weekly_course_3_7, R.id.weekly_course_3_8),
                intArrayOf(R.id.weekly_course_4_1, R.id.weekly_course_4_2, R.id.weekly_course_4_3, R.id.weekly_course_4_4, R.id.weekly_course_4_5, R.id.weekly_course_4_6, R.id.weekly_course_4_7, R.id.weekly_course_4_8),
                intArrayOf(R.id.weekly_course_5_1, R.id.weekly_course_5_2, R.id.weekly_course_5_3, R.id.weekly_course_5_4, R.id.weekly_course_5_5, R.id.weekly_course_5_6, R.id.weekly_course_5_7, R.id.weekly_course_5_8),
                intArrayOf(R.id.weekly_course_6_1, R.id.weekly_course_6_2, R.id.weekly_course_6_3, R.id.weekly_course_6_4, R.id.weekly_course_6_5, R.id.weekly_course_6_6, R.id.weekly_course_6_7, R.id.weekly_course_6_8),
                intArrayOf(R.id.weekly_course_7_1, R.id.weekly_course_7_2, R.id.weekly_course_7_3, R.id.weekly_course_7_4, R.id.weekly_course_7_5, R.id.weekly_course_7_6, R.id.weekly_course_7_7, R.id.weekly_course_7_8),
            )
            val currentWeekday = ((Calendar.getInstance().get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1
            dayIds.forEachIndexed { index, id ->
                val count = (0 until courses.length()).count { courses.optJSONObject(it)?.optInt("weekday", 0) == index + 1 }
                views.setTextViewText(id, "${dayNames[index]}  $count")
                views.setInt(id, "setBackgroundColor", if (index + 1 == currentWeekday) 0xFFE8DEF8.toInt() else 0xFFF3F1F6.toInt())
                views.setViewVisibility(id, View.VISIBLE)
                val dayCourses = buildList {
                    for (courseIndex in 0 until courses.length()) {
                        val course = courses.optJSONObject(courseIndex) ?: continue
                        if (course.optInt("weekday", 0) == index + 1) add(course)
                    }
                }.sortedBy { it.optInt("startSection", 0) }
                courseIds[index].forEachIndexed { slot, courseId ->
                    val course = dayCourses.getOrNull(slot)
                    if (course == null) {
                        views.setViewVisibility(courseId, View.INVISIBLE)
                    } else {
                        val text = "${course.optString("time")}\n${course.optString("name", "课程")}"
                        views.setTextViewText(courseId, text)
                        views.setInt(courseId, "setBackgroundColor", if (course.optBoolean("ongoing")) 0xFF6750A4.toInt() else 0xFFE8DEF8.toInt())
                        views.setTextColor(courseId, if (course.optBoolean("ongoing")) 0xFFFFFFFF.toInt() else 0xFF1D1B20.toInt())
                        views.setViewVisibility(courseId, View.VISIBLE)
                        views.setOnClickPendingIntent(
                            courseId,
                            openItemAppIntent(
                                context,
                                "schedule",
                                "weekly",
                                course.optString("itemKey"),
                                course.optInt("week").takeIf { it > 0 },
                                index + 1,
                                course.optInt("startSection").takeIf { it > 0 },
                            ),
                        )
                    }
                }
            }
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, "schedule", "weekly"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun updateExamsWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_exams)
            views.setTextViewText(R.id.widget_header_title, "考试倒计时")
            val rows = intArrayOf(R.id.exam_row_1, R.id.exam_row_2, R.id.exam_row_3)
            val exams = JSONArray(prefs.getString("examItemsJson", "[]") ?: "[]")
            rows.forEachIndexed { index, id ->
                val exam = exams.optJSONObject(index)
                if (exam == null) {
                    views.setViewVisibility(id, View.GONE)
                } else {
                    val days = exam.optInt("days", 9999)
                    val countdown = when {
                        days == 0 -> "今天"
                        days == 9999 -> "日期待定"
                        days < 0 -> "${-days} 天前"
                        else -> "还有 $days 天"
                    }
                    views.setTextViewText(id, "$countdown  ${exam.optString("name", "考试")}\n${exam.optString("date")} · ${exam.optString("time")} · ${exam.optString("location")}")
                    views.setViewVisibility(id, View.VISIBLE)
                    views.setOnClickPendingIntent(
                        id,
                        openItemAppIntent(context, "exams", "exams", exam.optString("name"), null, null, null),
                    )
                }
            }
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, "exams", "exams"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun updateGradesWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            prefs: android.content.SharedPreferences,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_grades)
            views.setTextViewText(R.id.widget_header_title, "本学期成绩")
            views.setTextViewText(R.id.grade_gpa, "绩点\n${prefText(prefs, "gradeGpa", "-")}")
            views.setTextViewText(R.id.grade_average, "平均分\n${prefText(prefs, "gradeAverage", "-")}")
            val grades = JSONArray(prefs.getString("gradeItemsJson", "[]") ?: "[]")
            val rows = buildList {
                for (index in 0 until minOf(4, grades.length())) {
                    val grade = grades.optJSONObject(index) ?: continue
                    add(grade)
                }
            }
            val rowIds = intArrayOf(R.id.grade_row_1, R.id.grade_row_2, R.id.grade_row_3, R.id.grade_row_4)
            rowIds.forEachIndexed { index, id ->
                val grade = rows.getOrNull(index)
                if (grade == null) {
                    views.setViewVisibility(id, if (index == 0 && rows.isEmpty()) View.VISIBLE else View.GONE)
                    if (index == 0 && rows.isEmpty()) views.setTextViewText(id, "暂无成绩数据")
                } else {
                    val courseName = grade.optString("courseName", grade.optString("name", "课程"))
                    views.setViewVisibility(id, View.VISIBLE)
                    views.setTextViewText(id, "$courseName  ${grade.optString("score", "-")} 分")
                    views.setOnClickPendingIntent(
                        id,
                        openItemAppIntent(context, "grades", "grades", courseName, null, null, null),
                    )
                }
            }
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context, "grades", "grades"))
            manager.updateAppWidget(widgetId, views)
        }

        private fun widgetData(prefs: android.content.SharedPreferences, kind: String): WidgetData {
            return when (kind) {
                "today" -> WidgetData(
                    headerTitle = "今日课表",
                    title = prefText(prefs, "todayTitle", "今日课表"),
                    meta = prefText(prefs, "todayMeta", "课程提醒"),
                    detail = readList(prefs.getString("todayItems", "[]")).joinToString("\n").ifBlank { "暂无课程" },
                    tab = "schedule"
                )
                "utilities" -> WidgetData(
                    headerTitle = "生活缴费",
                    title = prefText(prefs, "utilityTitle", "水电费余额"),
                    meta = prefText(prefs, "utilityMeta", "暂无数据"),
                    detail = prefText(prefs, "utilityDetail", "点击查看生活缴费"),
                    tab = "ecard"
                )
                "progress" -> WidgetData(
                    headerTitle = "办事大厅",
                    title = prefText(prefs, "progressTitle", "业务进度"),
                    meta = prefText(prefs, "progressMeta", "暂无业务进度"),
                    detail = prefText(prefs, "progressDetail", "点击查看办事大厅"),
                    tab = "business"
                )
                "exams" -> {
                    val exams = JSONArray(prefs.getString("examItemsJson", "[]") ?: "[]")
                    val first = exams.optJSONObject(0)
                    val title = first?.optString("courseName").orEmpty()
                        .ifBlank { first?.optString("name").orEmpty() }
                    WidgetData(
                        headerTitle = "考试倒计时",
                        title = title.ifBlank { "暂无考试" },
                        meta = prefText(prefs, "examCount", "0") + " 场考试",
                        detail = first?.optString("time", "点击查看考试安排") ?: "点击查看考试安排",
                        tab = "exams"
                    )
                }
                "grades" -> WidgetData(
                    headerTitle = "本学期成绩",
                    title = prefText(prefs, "gradeGpa", "暂无成绩"),
                    meta = "平均绩点 · " + prefText(prefs, "gradeAverage", "-") + " 分",
                    detail = prefText(prefs, "gradeCount", "0") + " 门课程",
                    tab = "grades"
                )
                else -> WidgetData(
                    headerTitle = "下一节课",
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

        private fun openItemAppIntent(
            context: Context,
            tab: String,
            kind: String,
            itemKey: String,
            week: Int?,
            weekday: Int?,
            startSection: Int?,
        ): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_INITIAL_TAB, tab)
                putExtra(EXTRA_WIDGET_KIND, kind)
                putExtra("itemKey", itemKey)
                week?.let { putExtra("week", it) }
                weekday?.let { putExtra("weekday", it) }
                startSection?.let { putExtra("startSection", it) }
            }
            return PendingIntent.getActivity(
                context,
                (kind + itemKey).hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun itemIntent(itemKey: String, week: Int?, weekday: Int?, startSection: Int?): Intent {
            return Intent().apply {
                putExtra("itemKey", itemKey)
                week?.let { putExtra("week", it) }
                weekday?.let { putExtra("weekday", it) }
                startSection?.let { putExtra("startSection", it) }
            }
        }
    }
}

data class WidgetData(
    val headerTitle: String,
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

class ExamCountdownWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "exams"
}

class GradesWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "grades"
}

class UtilitiesWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "utilities"
}

class BusinessProgressWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "progress"
}

class WeeklyScheduleWidgetProvider : HomeWidgetProvider() {
    override val kind: String = "weekly"
}
