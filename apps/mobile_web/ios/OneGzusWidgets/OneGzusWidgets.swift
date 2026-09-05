import SwiftUI
import WidgetKit

private let appGroupIdentifier = "group.cn.gzus.pro.6772c5tf6c"
private let nextClassHomeScreenWidgetKind = "OneGzusNextClassHomeScreen"
private let nextClassLockScreenWidgetKind = "OneGzusNextClassLockScreen"
private let todayCoursesWidgetKind = "OneGzusTodayCourses"
private let examCountdownWidgetKind = "OneGzusExamCountdown"
private let gradesWidgetKind = "OneGzusGrades"
private let utilitiesWidgetKind = "OneGzusUtilities"
private let progressWidgetKind = "OneGzusProgress"
private let weeklyScheduleWidgetKind = "OneGzusWeeklySchedule"

private struct TodayCourse: Decodable {
    let itemKey: String?
    let week: Int?
    let weekday: Int?
    let startSection: Int?
    let time: String
    let name: String
    let info: String
    let ongoing: Bool
}
private struct Exam: Decodable { let name: String; let date: String; let time: String; let location: String; let days: Int; let urgent: Bool }
private struct Grade: Decodable { let name: String; let score: String; let credit: String; let gpa: String }
private struct ProgressItem: Decodable { let title: String; let status: String; let node: String; let progress: String; let date: String }
private struct WeeklyCourse: Decodable {
    let itemKey: String
    let week: Int?
    let weekday: Int
    let startSection: Int
    let endSection: Int
    let time: String
    let name: String
    let classroom: String
    let teacher: String
    let ongoing: Bool
}

private struct Dashboard {
    let nextTitle: String
    let nextTime: String
    let nextLocation: String
    let nextTeacher: String
    let nextStatus: String
    let nextStart: Date?
    let nextEnd: Date?
    let todayTitle: String
    let todayMeta: String
    let todayCourses: [TodayCourse]
    let exams: [Exam]
    let gradeGpa: String
    let gradeAverage: String
    let gradeCount: String
    let grades: [Grade]
    let utilityIsBound: Bool
    let utilityLowPower: Bool
    let utilityTitle: String
    let utilityColdWater: String
    let utilityHotWater: String
    let utilityElectricity: String
    let utilityRoomInfo: String
    let progressTitle: String
    let progressMeta: String
    let progressDetail: String
    let progressItems: [ProgressItem]
    let weeklyCourses: [WeeklyCourse]

    static func load() -> Dashboard {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        return Dashboard(
            nextTitle: string(defaults, "nextTitle", "暂无下一节课"),
            nextTime: string(defaults, "nextTime", ""),
            nextLocation: string(defaults, "nextClassroom", ""),
            nextTeacher: string(defaults, "nextTeacher", ""),
            nextStatus: string(defaults, "nextStatus", "none"),
            nextStart: date(number(defaults, "nextStartEpochMillis")),
            nextEnd: date(number(defaults, "nextEndEpochMillis")),
            todayTitle: string(defaults, "todayTitle", "今日课程"),
            todayMeta: string(defaults, "todayMeta", ""),
            todayCourses: decode(defaults, "todayCoursesJson"),
            exams: decode(defaults, "examItemsJson"),
            gradeGpa: string(defaults, "gradeGpa", "0.00"),
            gradeAverage: string(defaults, "gradeAverage", "0.0"),
            gradeCount: string(defaults, "gradeCount", "0"),
            grades: decode(defaults, "gradeItemsJson"),
            utilityIsBound: defaults?.bool(forKey: "utilityIsBound") ?? false,
            utilityLowPower: defaults?.bool(forKey: "utilityLowPower") ?? false,
            utilityTitle: string(defaults, "utilityTitle", "未绑定宿舍"),
            utilityColdWater: string(defaults, "utilityColdWater", "-"),
            utilityHotWater: string(defaults, "utilityHotWater", "-"),
            utilityElectricity: string(defaults, "utilityElectricity", "-"),
            utilityRoomInfo: string(defaults, "utilityRoomInfo", ""),
            progressTitle: string(defaults, "progressTitle", "暂无业务进度"),
            progressMeta: string(defaults, "progressMeta", ""),
            progressDetail: string(defaults, "progressDetail", "点击查看办事大厅"),
            progressItems: decode(defaults, "progressItemsJson"),
            weeklyCourses: decode(defaults, "weeklyCoursesJson")
        )
    }
}

private func string(_ defaults: UserDefaults?, _ key: String, _ fallback: String) -> String { defaults?.string(forKey: key) ?? fallback }
private func number(_ defaults: UserDefaults?, _ key: String) -> Int64 { (defaults?.object(forKey: key) as? NSNumber)?.int64Value ?? 0 }
private func date(_ milliseconds: Int64) -> Date? { milliseconds > 0 ? Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000) : nil }
private func decode<Value: Decodable>(_ defaults: UserDefaults?, _ key: String) -> [Value] {
    guard let raw = defaults?.string(forKey: key), let data = raw.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([Value].self, from: data)) ?? []
}

private struct Entry: TimelineEntry { let date: Date; let dashboard: Dashboard }
private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), dashboard: sample()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), dashboard: Dashboard.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        WidgetSnapshotStore.refreshIfNeeded {
            completion(timeline(now: Date(), dashboard: Dashboard.load()))
        }
    }

    private func timeline(now: Date, dashboard: Dashboard) -> Timeline<Entry> {
        var entries = [Entry(date: now, dashboard: dashboard)]
        for point in [dashboard.nextStart, dashboard.nextEnd].compactMap({ $0 }).filter({ $0 > now }) { entries.append(Entry(date: point, dashboard: dashboard)) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }
}

private func sample() -> Dashboard {
    Dashboard(
        nextTitle: "数据结构", nextTime: "10:10-11:50", nextLocation: "教学楼 A301", nextTeacher: "张老师", nextStatus: "upcoming", nextStart: Date().addingTimeInterval(1_800), nextEnd: Date().addingTimeInterval(7_800),
        todayTitle: "今日 3 节课", todayMeta: "第 6 周 · 3 节课",
        todayCourses: [TodayCourse(itemKey: "course-1:1:1", week: 1, weekday: 1, startSection: 1, time: "08:30", name: "数据结构", info: "教学楼 A301 · 张老师", ongoing: false), TodayCourse(itemKey: "course-2:1:3", week: 1, weekday: 1, startSection: 3, time: "10:10", name: "软件工程", info: "教学楼 B204 · 李老师", ongoing: true), TodayCourse(itemKey: "course-3:1:7", week: 1, weekday: 1, startSection: 7, time: "14:30", name: "数据库原理", info: "教学楼 C105 · 王老师", ongoing: false)],
        exams: [Exam(name: "数据结构", date: "6月20日", time: "09:00-11:00", location: "教学楼 A301", days: 3, urgent: true), Exam(name: "软件工程", date: "6月23日", time: "14:30-16:30", location: "教学楼 B204", days: 6, urgent: false)],
        gradeGpa: "3.72", gradeAverage: "86.5", gradeCount: "8", grades: [Grade(name: "数据结构", score: "94", credit: "3", gpa: "4.0"), Grade(name: "软件工程", score: "90", credit: "2", gpa: "4.0")],
        utilityIsBound: true, utilityLowPower: false, utilityTitle: "南区 3 栋 301", utilityColdWater: "18.2 吨", utilityHotWater: "26.0 元", utilityElectricity: "42.6 度", utilityRoomInfo: "更新于今天 08:00",
        progressTitle: "请假申请", progressMeta: "待办 · 审批中", progressDetail: "辅导员审批 · 60%", progressItems: [ProgressItem(title: "请假申请", status: "审批中", node: "辅导员审批", progress: "60", date: "今天"), ProgressItem(title: "奖学金申请", status: "待提交", node: "材料准备", progress: "20", date: "明天"), ProgressItem(title: "证明开具", status: "已办", node: "完成", progress: "100", date: "昨天")],
        weeklyCourses: [
            WeeklyCourse(itemKey: "course-1:1:1", week: 1, weekday: 1, startSection: 1, endSection: 2, time: "09:00-10:20", name: "数据结构", classroom: "A301", teacher: "张老师", ongoing: false),
            WeeklyCourse(itemKey: "course-2:2:3", week: 1, weekday: 2, startSection: 3, endSection: 4, time: "10:40-12:00", name: "软件工程", classroom: "B204", teacher: "李老师", ongoing: false),
            WeeklyCourse(itemKey: "course-3:4:7", week: 1, weekday: 4, startSection: 7, endSection: 8, time: "14:00-15:20", name: "数据库原理", classroom: "C105", teacher: "王老师", ongoing: false),
        ]
    )
}

private func targetURL(_ tab: String) -> URL {
    guard let url = URL(string: "cn.gzus.pro://widget?tab=\(tab)") else { fatalError("无效 Widget 跳转：\(tab)") }
    return url
}
private func targetURL(_ tab: String, itemKey: String?, week: Int? = nil, weekday: Int? = nil, startSection: Int? = nil) -> URL {
    var components = URLComponents()
    components.scheme = "cn.gzus.pro"
    components.host = "widget"
    var items = [URLQueryItem(name: "tab", value: tab)]
    if let itemKey, !itemKey.isEmpty { items.append(URLQueryItem(name: "itemKey", value: itemKey)) }
    if let week { items.append(URLQueryItem(name: "week", value: String(week))) }
    if let weekday { items.append(URLQueryItem(name: "weekday", value: String(weekday))) }
    if let startSection { items.append(URLQueryItem(name: "startSection", value: String(startSection))) }
    components.queryItems = items
    guard let url = components.url else { fatalError("无效 Widget 跳转：\(tab)") }
    return url
}
private func nextLocation(_ dashboard: Dashboard) -> String { dashboard.nextLocation.isEmpty ? "地点待定" : dashboard.nextLocation }
private func nextTimeText(_ dashboard: Dashboard) -> String { dashboard.nextTime.isEmpty ? "时间待定" : dashboard.nextTime }
private func nextHeading(_ dashboard: Dashboard, _ now: Date) -> String {
    guard dashboard.nextStatus != "none", let start = dashboard.nextStart else { return "暂无课程" }
    if let end = dashboard.nextEnd, now >= end { return "课程已结束" }
    return now >= start ? "进行中" : "下一节课"
}
private func nextText(_ dashboard: Dashboard, _ now: Date) -> String {
    guard dashboard.nextStatus != "none", let start = dashboard.nextStart else {
        return dashboard.nextTitle == "今明无课" ? "今明无课" : "打开软帮手查看课表"
    }
    if let end = dashboard.nextEnd, now >= end { return "打开软帮手刷新课程" }
    return now >= start ? "\(dashboard.nextTitle) · 进行中" : dashboard.nextTitle
}
private func countdown(_ exam: Exam) -> String {
    if exam.days == 9999 { return "日期待定" }
    if exam.days == 0 { return "今天考试" }
    if exam.days < 0 { return "\(abs(exam.days)) 天前" }
    return "还有 \(exam.days) 天"
}

private struct Header: View {
    let title: String; let icon: String; let badge: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
private struct CourseLine: View {
    let course: TodayCourse; let compact: Bool
    var body: some View {
        HStack(alignment: .top, spacing: compact ? 6 : 8) {
            Text(course.time).font(compact ? .caption2 : .caption).foregroundStyle(.secondary).frame(width: compact ? 36 : 42, alignment: .leading)
            Circle().fill(course.ongoing ? .red : .accentColor).frame(width: compact ? 6 : 8, height: compact ? 6 : 8).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold)).lineLimit(1)
                Text(course.info).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct NextClassHomeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let dashboard = entry.dashboard
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 6) {
                Header(title: nextHeading(dashboard, entry.date), icon: dashboard.nextStatus == "ongoing" ? "play.circle.fill" : "clock", badge: "")
                Text(nextText(dashboard, entry.date)).font(.headline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.78)
                Divider()
                HStack(spacing: 5) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(dashboard.nextTime.isEmpty ? "时间待定" : dashboard.nextTime).lineLimit(1).minimumScaleFactor(0.7)
                }.font(.caption)
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                    Text(nextLocation(dashboard)).lineLimit(2).minimumScaleFactor(0.7)
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "person").foregroundStyle(.secondary)
                    Text(dashboard.nextTeacher.isEmpty ? "教师待定" : dashboard.nextTeacher).lineLimit(1).minimumScaleFactor(0.7)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding().widgetURL(targetURL("schedule"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Header(title: nextHeading(dashboard, entry.date), icon: dashboard.nextStatus == "ongoing" ? "play.circle.fill" : "clock", badge: dashboard.nextTime.isEmpty ? "待定" : dashboard.nextTime)
                Text(nextText(dashboard, entry.date)).font(.title3.weight(.semibold)).lineLimit(1)
                Text(nextLocation(dashboard)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(dashboard.nextTeacher.isEmpty ? "教师待定" : dashboard.nextTeacher).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding().widgetURL(targetURL("schedule"))
        }
    }
}
private struct NextClassHomeWidget: Widget {
    let kind = nextClassHomeScreenWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { NextClassHomeView(entry: $0) }
            .configurationDisplayName("下一节课").description("查看下一节课程、时间、地点与教师。").supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TodayCoursesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let courses = entry.dashboard.todayCourses
        let limit = family == .systemMedium ? 2 : 3
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "今日时间线", icon: "list.bullet", badge: "\(courses.count) 节")
            if courses.isEmpty { Spacer(); Text("今日无课").font(.headline); Spacer() }
            else {
                ForEach(Array(courses.prefix(limit).enumerated()), id: \.offset) { _, course in
                    Link(destination: targetURL("schedule", itemKey: course.itemKey, week: course.week, weekday: course.weekday, startSection: course.startSection)) {
                        CourseLine(course: course, compact: family != .systemLarge)
                    }
                }
                if family == .systemLarge { Spacer(minLength: 0); Text(entry.dashboard.todayMeta).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding().widgetURL(targetURL("schedule"))
    }
}
private struct TodayCoursesWidget: Widget {
    let kind = todayCoursesWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { TodayCoursesView(entry: $0) }
            .configurationDisplayName("今日时间线").description("按时间顺序查看今天的课程。").supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct ExamRow: View {
    let exam: Exam
    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Text(exam.days == 9999 ? "?" : exam.days == 0 ? "!" : "\(abs(exam.days))").font(.title3.weight(.bold)).foregroundStyle(exam.urgent ? Color.red : Color.accentColor)
                Text(exam.days == 0 ? "今天" : exam.days == 9999 ? "待定" : "天").font(.caption2).foregroundStyle(.secondary)
            }.frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(exam.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(exam.time) · \(exam.location)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
private struct ExamColumn: View {
    let exam: Exam
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(exam.days == 9999 ? "?" : exam.days == 0 ? "!" : "\(abs(exam.days))")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(exam.urgent ? Color.red : Color.accentColor)
                Text(exam.days == 0 ? "今天" : exam.days == 9999 ? "待定" : "天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(exam.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
            Text(exam.date)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(exam.time)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(exam.location)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct ExamCountdownView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let exams = entry.dashboard.exams
        let limit = family == .systemSmall ? 1 : family == .systemMedium ? 2 : 3
        VStack(alignment: .leading, spacing: 8) {
            Header(title: family == .systemSmall ? "考试" : "考试倒计时", icon: "timer", badge: "\(exams.count)")
            if let first = exams.first {
                if family == .systemSmall {
                    Spacer(minLength: 0)
                    Text(first.name)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(countdown(first))
                        .font(.title3.weight(first.urgent ? .bold : .semibold))
                        .foregroundStyle(first.urgent ? Color.red : Color.accentColor)
                        .lineLimit(1)
                    Text("\(first.date) · \(first.time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(first.location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if family == .systemMedium {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(exams.prefix(2).enumerated()), id: \.offset) { _, exam in
                            Link(destination: targetURL("exams", itemKey: exam.name)) { ExamColumn(exam: exam) }
                        }
                    }
                } else {
                    ForEach(Array(exams.prefix(limit).enumerated()), id: \.offset) { _, exam in
                        Link(destination: targetURL("exams", itemKey: exam.name)) { ExamRow(exam: exam) }
                    }
                }
            } else {
                Spacer()
                Text(family == .systemSmall ? "暂无考试" : "暂无即将到来的考试")
                    .font(.headline)
                Spacer()
            }
        }.padding().widgetURL(targetURL("exams"))
    }
}
private struct ExamCountdownWidget: Widget {
    let kind = examCountdownWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { ExamCountdownView(entry: $0) }
            .configurationDisplayName("考试倒计时").description("按首页考试卡片查看最近考试。").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct Metric: View {
    let value: String; let label: String; let accent: Bool
    var body: some View { VStack(spacing: 2) { Text(value).font(.title2.weight(.bold)).foregroundStyle(accent ? Color.accentColor : Color.primary); Text(label).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}
private struct GradesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let dashboard = entry.dashboard
        VStack(alignment: .leading, spacing: 8) {
            Header(title: family == .systemSmall ? "成绩" : "本学期成绩", icon: "graduationcap", badge: "\(dashboard.gradeCount) 门")
            if dashboard.gradeCount == "0" { Spacer(); Text("暂无成绩数据").font(.headline); Spacer() }
            else if family == .systemSmall { Spacer(); Text(dashboard.gradeGpa).font(.title.weight(.bold)).foregroundStyle(Color.accentColor); Text("平均绩点").font(.caption).foregroundStyle(.secondary); Spacer() }
            else {
                HStack { Metric(value: dashboard.gradeGpa, label: "平均绩点", accent: true); Divider(); Metric(value: dashboard.gradeAverage, label: "平均分", accent: false) }
                if family == .systemLarge { Divider(); ForEach(Array(dashboard.grades.prefix(2).enumerated()), id: \.offset) { _, grade in Link(destination: targetURL("grades", itemKey: grade.name)) { HStack { VStack(alignment: .leading, spacing: 1) { Text(grade.name).font(.caption.weight(.semibold)).lineLimit(1); Text(grade.credit.isEmpty ? "" : "\(grade.credit) 学分").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text(grade.score).font(.subheadline.weight(.bold)); Text(grade.gpa).font(.caption).foregroundStyle(.secondary) } } } }
            }
        }.padding().widgetURL(targetURL("grades"))
    }
}
private struct GradesWidget: Widget {
    let kind = gradesWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { GradesView(entry: $0) }
            .configurationDisplayName("本学期成绩").description("复用首页平均绩点、平均分与成绩摘要。").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct UtilityTile: View {
    let title: String; let value: String; let icon: String; let accent: Color; let compact: Bool
    var body: some View {
        VStack(spacing: compact ? 2 : 3) {
            Image(systemName: icon).font(compact ? .caption2 : .caption).foregroundStyle(accent)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(compact ? .caption2.weight(.bold) : .caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.55)
        }.frame(maxWidth: .infinity)
    }
}
private struct UtilitiesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let dashboard = entry.dashboard
        VStack(alignment: .leading, spacing: 8) {
            Header(title: family == .systemSmall ? "水电" : "水电余额", icon: "drop", badge: dashboard.utilityIsBound ? "实时" : "未绑定")
            if !dashboard.utilityIsBound { Spacer(); Text("点击绑定宿舍").font(.headline); if family != .systemSmall { Text("绑定后可查看水电余额").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            else {
                Spacer(minLength: 0)
                HStack(spacing: family == .systemSmall ? 4 : 8) {
                    UtilityTile(title: "冷水", value: dashboard.utilityColdWater, icon: "drop.fill", accent: .blue, compact: family == .systemSmall)
                    UtilityTile(title: "热水", value: dashboard.utilityHotWater, icon: "flame.fill", accent: .red, compact: family == .systemSmall)
                    UtilityTile(title: "电费", value: dashboard.utilityElectricity, icon: "bolt.fill", accent: dashboard.utilityLowPower ? .red : .orange, compact: family == .systemSmall)
                }
                Spacer(minLength: 0)
            }
        }.padding().widgetURL(targetURL("ecard"))
    }
}
private struct UtilitiesWidget: Widget {
    let kind = utilitiesWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { UtilitiesView(entry: $0) }
            .configurationDisplayName("水电余额").description("显示冷水、热水和电费余额。").supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ProgressRow: View {
    let item: ProgressItem
    var body: some View { HStack(spacing: 7) { VStack(alignment: .leading, spacing: 1) { Text(item.title).font(.caption.weight(.semibold)).lineLimit(1); Text([item.status, item.node].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if !item.progress.isEmpty { Text("\(item.progress)%").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) } } }
}
private struct ProgressView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let dashboard = entry.dashboard
        let limit = family == .systemSmall ? 1 : family == .systemMedium ? 2 : 3
        VStack(alignment: .leading, spacing: 8) {
            Header(title: family == .systemSmall ? "业务" : "业务进度", icon: "point.topleft.down.curvedto.point.bottomright.up", badge: dashboard.progressMeta)
            if dashboard.progressItems.isEmpty { Spacer(); Text("暂无业务进度").font(.headline); Spacer() }
            else if family == .systemSmall { Text(dashboard.progressItems[0].title).font(.headline).lineLimit(1); Text(dashboard.progressItems[0].status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            else { ForEach(Array(dashboard.progressItems.prefix(limit).enumerated()), id: \.offset) { _, item in Link(destination: targetURL("business", itemKey: item.title)) { ProgressRow(item: item) } }; if family == .systemLarge { Spacer(minLength: 0); Text(dashboard.progressDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
        }.padding().widgetURL(targetURL("business"))
    }
}
private struct ProgressWidget: Widget {
    let kind = progressWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { ProgressView(entry: $0) }
            .configurationDisplayName("业务进度").description("复用首页业务分类与进度数据。").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private let weeklyDayNames = ["一", "二", "三", "四", "五", "六", "日"]

private struct WeeklyScheduleView: View {
    let entry: Entry

    private var todayWeekday: Int {
        Calendar.current.component(.weekday, from: entry.date) == 1
            ? 7
            : Calendar.current.component(.weekday, from: entry.date) - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "本周课表", icon: "calendar", badge: "第\(todayWeekday)天")
            if entry.dashboard.weeklyCourses.isEmpty {
                Spacer()
                Text("本周暂无课程").font(.headline)
                Spacer()
            } else {
                WeeklyCalendarGrid(
                    courses: entry.dashboard.weeklyCourses,
                    todayWeekday: todayWeekday
                )
            }
        }
        .padding()
        .widgetURL(targetURL("schedule", itemKey: nil))
    }
}

private struct WeeklyCalendarGrid: View {
    let courses: [WeeklyCourse]
    let todayWeekday: Int

    private let sectionCount = 8

    var body: some View {
        GeometryReader { proxy in
            let timeColumnWidth = max(18, proxy.size.width * 0.055)
            let dayWidth = (proxy.size.width - timeColumnWidth) / 7
            let headerHeight = min(28, proxy.size.height * 0.14)
            let rowHeight = max(20, (proxy.size.height - headerHeight) / CGFloat(sectionCount))
            let gridHeight = rowHeight * CGFloat(sectionCount)
            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    Color.clear.frame(width: timeColumnWidth)
                    ForEach(weeklyDayNames.indices, id: \.self) { index in
                        Text(weeklyDayNames[index])
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(index + 1 == todayWeekday ? Color.accentColor : .secondary)
                            .frame(width: dayWidth, height: headerHeight)
                            .background(index + 1 == todayWeekday ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                ZStack(alignment: .topLeading) {
                    ForEach(weeklyDayNames.indices, id: \.self) { index in
                        Rectangle()
                            .fill(index + 1 == todayWeekday ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
                            .frame(width: dayWidth, height: gridHeight)
                            .offset(x: timeColumnWidth + dayWidth * CGFloat(index))
                    }
                    ForEach(0...sectionCount, id: \.self) { row in
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: proxy.size.width, height: 0.5)
                            .offset(y: rowHeight * CGFloat(row))
                    }
                    ForEach(0..<sectionCount, id: \.self) { row in
                        Text("\(row + 1)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: timeColumnWidth, height: rowHeight)
                    }
                    ForEach(courses, id: \.itemKey) { course in
                        let start = min(max(course.startSection, 1), sectionCount)
                        let end = min(max(course.endSection, start), sectionCount)
                        let span = end - start + 1
                        Link(destination: targetURL("schedule", itemKey: course.itemKey, week: course.week, weekday: course.weekday, startSection: course.startSection)) {
                            Text(course.name)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(span > 1 ? 3 : 2)
                                .minimumScaleFactor(0.55)
                                .multilineTextAlignment(.center)
                                .frame(width: dayWidth - 4, height: rowHeight * CGFloat(span) - 4)
                                .background(Color.accentColor.opacity(course.ongoing ? 0.92 : 0.76), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .position(
                            x: timeColumnWidth + dayWidth * CGFloat(course.weekday - 1) + dayWidth / 2,
                            y: rowHeight * CGFloat(start - 1) + rowHeight * CGFloat(span) / 2
                        )
                    }
                }
                .frame(height: gridHeight)
            }
        }
    }
}

private struct WeeklyScheduleWidget: Widget {
    let kind = weeklyScheduleWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { WeeklyScheduleView(entry: $0) }
            .configurationDisplayName("本周课表")
            .description("按星期查看本周课程安排。")
            .supportedFamilies([.systemLarge])
    }
}

private struct NextClassLockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        let dashboard = entry.dashboard
        switch family {
        case .accessoryInline:
            Text("\(nextTimeText(dashboard)) · \(nextText(dashboard, entry.date)) · \(nextLocation(dashboard))")
        case .accessoryCircular:
            VStack(spacing: 1) {
                Text(nextTimeText(dashboard).prefix(5))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(nextText(dashboard, entry.date))
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(nextHeading(dashboard, entry.date)).font(.caption2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nextTimeText(dashboard)).font(.caption2)
                    Text(nextText(dashboard, entry.date)).font(.headline).lineLimit(1)
                }
                Text(nextLocation(dashboard)).font(.caption).lineLimit(1)
            }
        default:
            Text("\(nextText(dashboard, entry.date)) · \(nextLocation(dashboard))")
        }
    }
}
private struct NextClassLockScreenWidget: Widget {
    let kind = nextClassLockScreenWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { NextClassLockScreenView(entry: $0) }
            .configurationDisplayName("下一节课").description("在锁屏上查看下一节课程、时间与地点。").supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

@available(iOS 16.1, *)
private struct GzusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GzusLiveActivityAttributes.self) { context in
            GzusLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.attributes.deepLink))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.attributes.activityType == "ecard_reminder" ||
                        !hasLiveActivityCountdown(
                            context.state,
                            activityType: context.attributes.activityType
                        ) {
                        Image(systemName: liveActivityIcon(context.attributes.activityType))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(liveActivityColor(context.attributes.activityType))
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: liveActivityIcon(context.attributes.activityType))
                            Text(context.state.shortText)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(liveActivityColor(context.attributes.activityType))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if hasLiveActivityCountdown(
                        context.state,
                        activityType: context.attributes.activityType
                    ) {
                        GzusLiveActivityTimer(state: context.state)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        if context.attributes.activityType == "ecard_reminder" {
                            GzusUtilityMetrics(text: context.state.body)
                        } else {
                            Text(context.state.body)
                                .font(.caption)
                                .lineLimit(2)
                            if let progress = context.state.progress,
                               shouldShowLiveActivityProgress(progress) {
                                SwiftUI.ProgressView(value: progress, total: 1)
                                    .tint(liveActivityColor(context.attributes.activityType))
                                    .frame(height: 5)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: liveActivityIcon(context.attributes.activityType))
                    .foregroundStyle(liveActivityColor(context.attributes.activityType))
            } compactTrailing: {
                GzusLiveActivityCompactTrailing(context: context)
            } minimal: {
                Image(systemName: liveActivityIcon(context.attributes.activityType))
                    .foregroundStyle(liveActivityColor(context.attributes.activityType))
            }
            .widgetURL(URL(string: context.attributes.deepLink))
        }
        .configurationDisplayName("软帮手动态")
        .description("在灵动岛和锁屏查看教务动态。")
    }
}

@available(iOS 16.1, *)
private struct GzusLiveActivityLockScreenView: View {
    let context: ActivityViewContext<GzusLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(liveActivityColor(context.attributes.activityType).opacity(0.16))
                Image(systemName: liveActivityIcon(context.attributes.activityType))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(liveActivityColor(context.attributes.activityType))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if context.attributes.activityType == "ecard_reminder" {
                    GzusUtilityMetrics(text: context.state.body)
                } else {
                    Text(context.state.body)
                        .font(.subheadline)
                        .lineLimit(2)
                    if let progress = context.state.progress,
                       shouldShowLiveActivityProgress(progress) {
                        SwiftUI.ProgressView(value: progress, total: 1)
                            .tint(liveActivityColor(context.attributes.activityType))
                            .frame(height: 5)
                    }
                }
            }
            if hasLiveActivityCountdown(
                context.state,
                activityType: context.attributes.activityType
            ) {
                Spacer(minLength: 8)
                GzusLiveActivityTimer(state: context.state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
    }
}

@available(iOS 16.1, *)
private struct GzusLiveActivityCompactTrailing: View {
    let context: ActivityViewContext<GzusLiveActivityAttributes>

    var body: some View {
        if hasLiveActivityCountdown(
            context.state,
            activityType: context.attributes.activityType
        ) {
            GzusLiveActivityTimer(state: context.state)
        } else {
            Text(context.state.shortText)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(liveActivityColor(context.attributes.activityType))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 56, alignment: .trailing)
        }
    }
}

@available(iOS 16.1, *)
private struct GzusUtilityMetrics: View {
    let text: String

    private var values: [Substring] {
        text.split(whereSeparator: { $0 == "·" || $0 == "|" }).prefix(3).map { $0 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

@available(iOS 16.1, *)
private struct GzusLiveActivityTimer: View {
    let state: GzusLiveActivityAttributes.ContentState

    var body: some View {
        if let start = activityDate(state.startEpochMillis),
           let end = activityDate(state.endEpochMillis),
           end > start {
            Text(timerInterval: start...end, countsDown: true)
                .font(.caption.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.7)
        } else {
            Text(state.shortText)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
    }
}

@available(iOS 16.1, *)
private func activityDate(_ milliseconds: Int64) -> Date? {
    milliseconds > 0 ? Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000) : nil
}

@available(iOS 16.1, *)
private func hasLiveActivityCountdown(
    _ state: GzusLiveActivityAttributes.ContentState,
    activityType: String
) -> Bool {
    guard activityType == "course_reminder" || activityType == "exam_reminder" else {
        return false
    }
    guard let start = activityDate(state.startEpochMillis),
          let end = activityDate(state.endEpochMillis) else {
        return false
    }
    return end > start
}

@available(iOS 16.1, *)
private func shouldShowLiveActivityProgress(_ progress: Double) -> Bool {
    progress < 1
}

@available(iOS 16.1, *)
private func liveActivityIcon(_ type: String) -> String {
    switch type {
    case "course_reminder": return "clock"
    case "exam_reminder": return "doc.text.magnifyingglass"
    case "grade_update": return "graduationcap"
    case "ecard_reminder": return "drop"
    case "attendance_update": return "checkmark.seal"
    case "business_reminder", "business_update": return "building.2"
    default: return "bell"
    }
}

@available(iOS 16.1, *)
private func liveActivityColor(_ type: String) -> Color {
    switch type {
    case "exam_reminder", "attendance_update": return .orange
    case "ecard_reminder": return .cyan
    case "grade_update": return .green
    default: return .blue
    }
}

@main
struct OneGzusWidgets: WidgetBundle {
    var body: some Widget {
        NextClassHomeWidget()
        TodayCoursesWidget()
        ExamCountdownWidget()
        GradesWidget()
        UtilitiesWidget()
        ProgressWidget()
        WeeklyScheduleWidget()
        NextClassLockScreenWidget()
        if #available(iOS 16.1, *) {
            GzusLiveActivityWidget()
        }
    }
}
