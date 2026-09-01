import SwiftUI
import WidgetKit

private let appGroupIdentifier = "group.cn.gzus.pro.6772c5tf6c"
private let homeScreenWidgetKind = "OneGzusNextClassHomeScreen"
private let lockScreenWidgetKind = "OneGzusNextClassLockScreen"

private struct NextClassSnapshot {
    let title: String
    let time: String
    let location: String
    let status: String
    let startAt: Date?
    let endAt: Date?
    let updatedAt: Date?

    static func load() -> NextClassSnapshot {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let startValue = (defaults?.object(forKey: "nextStartEpochMillis") as? NSNumber)?.int64Value ?? 0
        let endValue = (defaults?.object(forKey: "nextEndEpochMillis") as? NSNumber)?.int64Value ?? 0
        let updatedValue = (defaults?.object(forKey: "widgetUpdatedAtEpochMillis") as? NSNumber)?.int64Value ?? 0
        return NextClassSnapshot(
            title: defaults?.string(forKey: "nextTitle") ?? "暂无下一节课",
            time: defaults?.string(forKey: "nextTime") ?? "",
            location: defaults?.string(forKey: "nextClassroom") ?? "",
            status: defaults?.string(forKey: "nextStatus") ?? "none",
            startAt: date(from: startValue),
            endAt: date(from: endValue),
            updatedAt: date(from: updatedValue)
        )
    }

    private static func date(from milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

private struct NextClassEntry: TimelineEntry {
    let date: Date
    let snapshot: NextClassSnapshot
}

private struct NextClassProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            snapshot: NextClassSnapshot(
                title: "数据结构",
                time: "10:10-11:50",
                location: "教学楼 A301",
                status: "upcoming",
                startAt: Date().addingTimeInterval(1_800),
                endAt: Date().addingTimeInterval(7_800),
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        completion(NextClassEntry(date: Date(), snapshot: NextClassSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let now = Date()
        let snapshot = NextClassSnapshot.load()
        var entries = [NextClassEntry(date: now, snapshot: snapshot)]
        if let startAt = snapshot.startAt, startAt > now {
            entries.append(NextClassEntry(date: startAt, snapshot: snapshot))
        }
        if let endAt = snapshot.endAt, endAt > now {
            entries.append(NextClassEntry(date: endAt, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private enum NextClassPresentation {
    static func heading(snapshot: NextClassSnapshot, now: Date) -> String {
        guard snapshot.status != "none", let startAt = snapshot.startAt else {
            return "暂无课程"
        }
        if let endAt = snapshot.endAt, now >= endAt {
            return "课程已结束"
        }
        return now >= startAt ? "进行中" : "下一节课"
    }

    static func time(snapshot: NextClassSnapshot, now: Date) -> String {
        guard snapshot.status != "none", snapshot.startAt != nil else { return "—" }
        if let endAt = snapshot.endAt, now >= endAt { return "—" }
        return snapshot.time.isEmpty ? "待定" : snapshot.time
    }

    static func title(snapshot: NextClassSnapshot, now: Date) -> String {
        guard snapshot.status != "none", let startAt = snapshot.startAt else {
            return "打开软帮手查看课表"
        }
        if let endAt = snapshot.endAt, now >= endAt {
            return "打开软帮手刷新课程"
        }
        return now >= startAt ? "(snapshot.title) · 进行中" : snapshot.title
    }
}

private struct NextClassHomeScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextClassEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    NextClassPresentation.heading(snapshot: entry.snapshot, now: entry.date),
                    systemImage: entry.snapshot.status == "ongoing" ? "play.circle.fill" : "clock"
                )
                .font(.caption.weight(.semibold))
                Spacer()
                Text(NextClassPresentation.time(snapshot: entry.snapshot, now: entry.date))
                    .font(.caption.weight(.bold))
            }

            Text(NextClassPresentation.title(snapshot: entry.snapshot, now: entry.date))
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .lineLimit(family == .systemSmall ? 2 : 1)

            if family == .systemMedium {
                Spacer(minLength: 0)
                Text(entry.snapshot.location.isEmpty ? "打开软帮手查看课表" : entry.snapshot.location)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
    }
}

private struct NextClassHomeScreenWidget: Widget {
    let kind = homeScreenWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassHomeScreenView(entry: entry)
        }
        .configurationDisplayName("下一节课")
        .description("在主屏幕查看下一节课程。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOS 16.0, *)
private struct NextClassLockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextClassEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("课表：\(NextClassPresentation.title(snapshot: entry.snapshot, now: entry.date))")
        case .accessoryCircular:
            VStack(spacing: 1) {
                Text(NextClassPresentation.heading(snapshot: entry.snapshot, now: entry.date))
                    .font(.system(size: 9, weight: .semibold))
                Text(NextClassPresentation.time(snapshot: entry.snapshot, now: entry.date).prefix(5))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: entry.snapshot.status == "ongoing" ? "play.circle.fill" : "clock")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NextClassPresentation.heading(snapshot: entry.snapshot, now: entry.date))
                        .font(.caption2)
                    Text(NextClassPresentation.title(snapshot: entry.snapshot, now: entry.date))
                        .font(.headline)
                        .lineLimit(1)
                    Text([NextClassPresentation.time(snapshot: entry.snapshot, now: entry.date), entry.snapshot.location]
                        .filter { !$0.isEmpty && $0 != "—" }
                        .joined(separator: " · "))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        default:
            Text(NextClassPresentation.title(snapshot: entry.snapshot, now: entry.date))
        }
    }
}

@available(iOS 16.0, *)
private struct NextClassLockScreenWidget: Widget {
    let kind = lockScreenWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassLockScreenView(entry: entry)
        }
        .configurationDisplayName("下一节课")
        .description("在锁屏上查看下一节课程。")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct OneGzusWidgets: WidgetBundle {
    var body: some Widget {
        NextClassHomeScreenWidget()
        if #available(iOS 16.0, *) {
            NextClassLockScreenWidget()
        }
    }
}
