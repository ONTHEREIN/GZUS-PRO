import Foundation
import Darwin

/// 主应用与 Widget 扩展共用文件锁，防止检查请求归属后被账号切换插入。
enum WidgetStorageTransactions {
  private static let processLock = NSRecursiveLock()
  private static var activeLockURL: URL?

  static func access<T>(lockURL: URL, operation: () throws -> T) throws -> T {
    processLock.lock()
    defer { processLock.unlock() }
    if activeLockURL == lockURL { return try operation() }
    guard activeLockURL == nil else { throw POSIXError(.EDEADLK) }
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer {
      if close(descriptor) != 0 { NSLog("widget_storage_close_failed: errno=%d", errno) }
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    activeLockURL = lockURL
    defer {
      activeLockURL = nil
      if flock(descriptor, LOCK_UN) != 0 {
        NSLog("widget_storage_unlock_failed: errno=%d", errno)
      }
    }
    return try operation()
  }

  static func commit(
    lockURL: URL,
    generationURL: URL,
    requestedGeneration: String,
    persist: () throws -> Bool
  ) throws -> Bool {
    try access(lockURL: lockURL) {
      guard FileManager.default.fileExists(atPath: generationURL.path),
            try String(contentsOf: generationURL, encoding: .utf8) == requestedGeneration else { return false }
      return try persist()
    }
  }
}

struct WidgetCourseTimelineItem: Codable, Equatable {
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
  let date: String?
}

struct WidgetNextClassState: Equatable {
  let title: String
  let time: String
  let location: String
  let teacher: String
  let status: String
  let start: Date?
  let end: Date?

  static let none = WidgetNextClassState(
    title: "暂无下一节课",
    time: "",
    location: "",
    teacher: "",
    status: "none",
    start: nil,
    end: nil
  )
}

enum WidgetNextClassTimeline {
  private struct DatedCourse {
    let source: WidgetCourseTimelineItem
    let start: Date
    let end: Date
    let time: String
  }

  private static let sectionTimes: [(String, String)] = [
    ("09:00", "09:40"), ("09:40", "10:20"), ("10:40", "11:20"), ("11:20", "12:00"),
    ("12:30", "13:10"), ("13:10", "13:50"), ("14:00", "14:40"), ("14:40", "15:20"),
    ("15:30", "16:10"), ("16:10", "16:50"), ("17:00", "17:40"), ("17:40", "18:20"),
    ("19:00", "19:40"), ("19:40", "20:20"), ("20:30", "21:10"), ("21:10", "21:50"),
  ]

  static func state(
    at now: Date,
    courses: [WidgetCourseTimelineItem],
    calendar: Calendar
  ) -> WidgetNextClassState {
    let datedCourses = datedCourses(courses, relativeTo: now, calendar: calendar)
    if let current = datedCourses.first(where: { $0.start <= now && now < $0.end }) {
      return makeState(current, status: "ongoing", now: now, calendar: calendar)
    }
    guard let upcoming = datedCourses.first(where: { $0.start >= now }) else {
      return .none
    }
    return makeState(upcoming, status: "upcoming", now: now, calendar: calendar)
  }

  static func transitionDates(
    after now: Date,
    courses: [WidgetCourseTimelineItem],
    calendar: Calendar
  ) -> [Date] {
    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    let values = datedCourses(courses, relativeTo: now, calendar: calendar)
      .flatMap { [$0.start, $0.end] }
      .filter { $0 > now && $0 < nextDay }
      .sorted()
    return values.reduce(into: [Date]()) { result, value in
      if result.last != value {
        result.append(value)
      }
    }
  }

  private static func makeState(_ course: DatedCourse, status: String, now: Date, calendar: Calendar) -> WidgetNextClassState {
    WidgetNextClassState(
      title: course.source.name,
      time: calendar.isDate(course.start, inSameDayAs: now) ? course.time : "\(course.source.date ?? "") \(course.time)".trimmingCharacters(in: .whitespaces),
      location: course.source.classroom,
      teacher: course.source.teacher,
      status: status,
      start: course.start,
      end: course.end
    )
  }

  private static func datedCourses(
    _ courses: [WidgetCourseTimelineItem],
    relativeTo now: Date,
    calendar: Calendar
  ) -> [DatedCourse] {
    let weekday = calendar.component(.weekday, from: now)
    let mondayOffset = weekday == 1 ? -6 : 2 - weekday
    let monday = calendar.date(
      byAdding: .day,
      value: mondayOffset,
      to: calendar.startOfDay(for: now)
    ) ?? calendar.startOfDay(for: now)
    return courses.compactMap { course in
      guard (1...7).contains(course.weekday),
            (1...16).contains(course.startSection),
            course.endSection >= course.startSection,
            course.endSection <= sectionTimes.count else {
        return nil
      }
      let startText = timeText(course.time, index: 0) ?? sectionTimes[course.startSection - 1].0
      let endText = timeText(course.time, index: 1) ?? sectionTimes[course.endSection - 1].1
      let day: Date
      if let actualDate = course.date {
        guard let parsed = WidgetCourseDates.parse(actualDate, calendar: calendar) else { return nil }
        day = parsed
      } else {
        guard let legacyDay = calendar.date(byAdding: .day, value: course.weekday - 1, to: monday) else { return nil }
        day = legacyDay
      }
      guard let start = date(startText, dayOffset: 0, from: day, calendar: calendar),
            let end = date(endText, dayOffset: 0, from: day, calendar: calendar),
            end > start else {
        return nil
      }
      return DatedCourse(source: course, start: start, end: end, time: "\(startText)-\(endText)")
    }.sorted {
      if $0.start != $1.start { return $0.start < $1.start }
      return $0.end < $1.end
    }
  }

  private static func timeText(_ value: String, index: Int) -> String? {
    let parts = value.split { character in
      character == "-" || character == "–" || character == "—" || character == "至"
    }
    guard parts.count > index else { return nil }
    let text = String(parts[index]).trimmingCharacters(in: .whitespacesAndNewlines)
    return parseMinutes(text) == nil ? nil : text
  }

  private static func parseMinutes(_ value: String) -> Int? {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
      return nil
    }
    return parts[0] * 60 + parts[1]
  }

  private static func date(
    _ value: String,
    dayOffset: Int,
    from monday: Date,
    calendar: Calendar
  ) -> Date? {
    guard let minutes = parseMinutes(value),
          let day = calendar.date(byAdding: .day, value: dayOffset, to: monday) else {
      return nil
    }
    return calendar.date(
      bySettingHour: minutes / 60,
      minute: minutes % 60,
      second: 0,
      of: day
    )
  }
}

enum WidgetCourseDates {
  static func parse(_ text: String, calendar: Calendar) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
          calendar.component(.year, from: day) == parts[0],
          calendar.component(.month, from: day) == parts[1],
          calendar.component(.day, from: day) == parts[2] else { return nil }
    return day
  }

  static func time(_ text: String, on day: Date, calendar: Calendar) -> Date? {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
    return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
  }
}

struct WidgetTodayCourse: Codable {
  let itemKey: String
  let date: String
  let week: Int?
  let weekday: Int
  let startSection: Int
  let time: String
  let name: String
  let info: String
  let ongoing: Bool
}

struct WidgetScheduleProjection {
  let weekly: [WidgetCourseTimelineItem]
  let today: [WidgetTodayCourse]
  let next: WidgetNextClassState
  let week: Int

  static func make(
    courses: [WidgetCourseTimelineItem], firstWeekStart: Date, now: Date, calendar: Calendar
  ) throws -> WidgetScheduleProjection {
    let todayStart = calendar.startOfDay(for: now)
    let weekday = ((calendar.component(.weekday, from: now) + 5) % 7) + 1
    guard let monday = calendar.date(byAdding: .day, value: 1 - weekday, to: todayStart),
          let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday) else {
      throw CocoaError(.coderReadCorrupt)
    }
    let firstWeekday = ((calendar.component(.weekday, from: firstWeekStart) + 5) % 7) + 1
    guard let firstMonday = calendar.date(byAdding: .day, value: 1 - firstWeekday, to: calendar.startOfDay(for: firstWeekStart)),
          let days = calendar.dateComponents([.day], from: firstMonday, to: monday).day else {
      throw CocoaError(.coderReadCorrupt)
    }
    var weekly: [WidgetCourseTimelineItem] = []
    var today: [WidgetTodayCourse] = []
    for course in courses.sorted(by: { ($0.date ?? "", $0.startSection) < ($1.date ?? "", $1.startSection) }) {
      guard let dateText = course.date,
            let day = WidgetCourseDates.parse(dateText, calendar: calendar),
            (1...16).contains(course.startSection),
            (course.startSection...16).contains(course.endSection),
            ((calendar.component(.weekday, from: day) + 5) % 7) + 1 == course.weekday else {
        throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "生效课程缺少有效日期、星期或节次"])
      }
      let times = course.time.split(separator: "-").map(String.init)
      guard times.count == 2,
            let start = WidgetCourseDates.time(times[0], on: day, calendar: calendar),
            let end = WidgetCourseDates.time(times[1], on: day, calendar: calendar), end > start else {
        throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "生效课程时间无效"])
      }
      let ongoing = start <= now && now < end
      if day >= monday && day < nextMonday {
        weekly.append(WidgetCourseTimelineItem(itemKey: course.itemKey, week: course.week,
          weekday: course.weekday, startSection: course.startSection, endSection: course.endSection,
          time: course.time, name: course.name, classroom: course.classroom, teacher: course.teacher,
          ongoing: ongoing, date: dateText))
      }
      if calendar.isDate(day, inSameDayAs: now) {
        today.append(WidgetTodayCourse(itemKey: course.itemKey, date: dateText, week: course.week,
          weekday: course.weekday, startSection: course.startSection, time: times[0], name: course.name,
          info: [course.classroom, course.teacher].filter { !$0.isEmpty }.joined(separator: " · "), ongoing: ongoing))
      }
    }
    return WidgetScheduleProjection(weekly: weekly, today: today,
      next: WidgetNextClassTimeline.state(at: now, courses: courses, calendar: calendar), week: days / 7 + 1)
  }
}

enum WidgetSnapshotStore {
  private static let appGroupIdentifier = "group.cn.gzus.pro.6772c5tf6c"
  private static let configurationKey = "widget_refresh_configuration"
  private static let etagKey = "widget_refresh_etag"
  private static let lastFetchKey = "widget_snapshot_last_fetch"
  private static let minimumFetchInterval: TimeInterval = 25 * 60
  private static let sectionTimes: [(String, String)] = [
    ("09:00", "09:40"), ("09:40", "10:20"), ("10:40", "11:20"), ("11:20", "12:00"),
    ("12:30", "13:10"), ("13:10", "13:50"), ("14:00", "14:40"), ("14:40", "15:20"),
    ("15:30", "16:10"), ("16:10", "16:50"), ("17:00", "17:40"), ("17:40", "18:20"),
    ("19:00", "19:40"), ("19:40", "20:20"), ("20:30", "21:10"), ("21:10", "21:50"),
  ]

  struct Configuration: Codable {
    let baseURL: String
    let sessionID: String
    let year: Int
    let term: Int
    let firstWeekStartEpochMillis: Int64
    let generation: String?
    let scheduleContext: String?

    func currentWeek(now: Date) -> Int {
      guard firstWeekStartEpochMillis > 0 else { return 1 }
      let calendar = Calendar.current
      let firstWeekStart = Date(timeIntervalSince1970: TimeInterval(firstWeekStartEpochMillis) / 1_000)
      let dayCount = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: firstWeekStart),
        to: calendar.startOfDay(for: now)
      ).day ?? 0
      return max(1, dayCount / 7 + 1)
    }
  }

  static func configure(
    baseURL: String,
    sessionID: String,
    year: Int,
    term: Int,
    firstWeekStartEpochMillis: Int64,
    scheduleContext: String
  ) throws {
    try withStorageAccess { defaults in
      let generation = UUID().uuidString
      let configuration = Configuration(
        baseURL: baseURL,
        sessionID: sessionID,
        year: year,
        term: term,
        firstWeekStartEpochMillis: firstWeekStartEpochMillis,
        generation: generation,
        scheduleContext: scheduleContext
      )
      let data = try JSONEncoder().encode(configuration)
      try Data(generation.utf8).write(to: generationURL(), options: .atomic)
      defaults.set(data, forKey: configurationKey)
      defaults.removeObject(forKey: etagKey)
      defaults.removeObject(forKey: lastFetchKey)
    }
  }

  private static func commitResponse(
    configuration: Configuration,
    persist: (UserDefaults) throws -> Bool
  ) throws -> Bool {
    guard let generation = configuration.generation else { return false }
    return try withStorageAccess { defaults in
      let markerURL = try generationURL()
      return try WidgetStorageTransactions.commit(
        lockURL: markerURL.deletingLastPathComponent().appendingPathComponent("widget-refresh.lock"),
        generationURL: markerURL,
        requestedGeneration: generation
      ) { try persist(defaults) }
    }
  }

  static func withStorageAccess<T>(_ operation: (UserDefaults) throws -> T) throws -> T {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "无法访问桌面组件共享存储"])
    }
    return try WidgetStorageTransactions.access(lockURL: directory.appendingPathComponent("widget-refresh.lock")) {
      try operation(defaults)
    }
  }

  private static func generationURL() throws -> URL {
    guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "无法访问桌面组件刷新配置"])
    }
    return directory.appendingPathComponent("widget-refresh-generation")
  }

  static func configuration() -> Configuration? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let data = defaults.data(forKey: configurationKey) else { return nil }
    return try? JSONDecoder().decode(Configuration.self, from: data)
  }

  static func nextClassCourses() -> [WidgetCourseTimelineItem] {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let raw = defaults.string(forKey: "effectiveCoursesJson"),
          let data = raw.data(using: .utf8) else {
      return []
    }
    return (try? JSONDecoder().decode([WidgetCourseTimelineItem].self, from: data)) ?? []
  }

  static func clearConfiguration() throws {
    try withStorageAccess { defaults in
      let markerURL = try generationURL()
      if FileManager.default.fileExists(atPath: markerURL.path) {
        try FileManager.default.removeItem(at: markerURL)
      }
      for key in defaults.dictionaryRepresentation().keys {
        if ["next", "today", "weekly", "effectiveCourses", "utility", "progress", "exam", "grade", "widget"].contains(where: { key.hasPrefix($0) }) {
          defaults.removeObject(forKey: key)
        }
      }
    }
  }

  @discardableResult
  static func refreshIfNeeded(completion: @escaping (Bool) -> Void) -> URLSessionDataTask? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let configuration = configuration() else {
      completion(false)
      return nil
    }
    let now = Date()
    // 跨日先投影具体日期缓存，网络失败时也不会继续显示昨天的今日/本周课程。
    var cacheProjected = false
    do {
      cacheProjected = try commitResponse(configuration: configuration) { defaults in
        guard defaults.string(forKey: "effectiveCoursesJson") != nil else { return false }
        try projectCachedSchedule(configuration: configuration, defaults: defaults)
        return true
      }
    } catch {
      NSLog("widget_schedule_project_failed: %@", error.localizedDescription)
    }
    if cacheProjected,
       let lastFetch = defaults.object(forKey: lastFetchKey) as? Date,
       now.timeIntervalSince(lastFetch) < minimumFetchInterval {
      completion(true)
      return nil
    }
    guard let components = URLComponents(
      string: "\(configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/widget-snapshot"
    ) else {
      completion(false)
      return nil
    }
    guard let url = components.url else {
      completion(false)
      return nil
    }
    var request = URLRequest(url: url)
    guard let scheduleContext = configuration.scheduleContext else {
      completion(false)
      return nil
    }
    request.httpMethod = "POST"
    request.httpBody = Data(scheduleContext.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 20
    request.setValue(configuration.sessionID, forHTTPHeaderField: "X-Session-Id")
    if let etag = defaults.string(forKey: etagKey) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      guard error == nil, let response = response as? HTTPURLResponse else {
        completion(false)
        return
      }
      do {
        let success = try commitResponse(configuration: configuration) { defaults -> Bool in
          if response.statusCode == 401 {
            try clearConfiguration()
            return false
          }
          guard response.statusCode == 200 || response.statusCode == 304 else { return false }
          if response.statusCode == 200 {
            guard let data, try storeSnapshot(data, configuration: configuration, defaults: defaults) else {
              return false
            }
          } else {
            try projectCachedSchedule(configuration: configuration, defaults: defaults)
          }
          defaults.set(Date(), forKey: lastFetchKey)
          if let etag = response.value(forHTTPHeaderField: "ETag") {
            defaults.set(etag, forKey: etagKey)
          }
          return true
        }
        completion(success)
      } catch {
        NSLog("widget_refresh_store_failed: %@", error.localizedDescription)
        completion(false)
      }
    }
    task.resume()
    return task
  }

  private static func storeSnapshot(_ data: Data, configuration: Configuration, defaults: UserDefaults) throws -> Bool {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modules = payload["modules"] as? [String: Any] else { return false }
    guard payload["scheduleFormat"] as? String == "dated-v1",
          let scheduleModule = modules["schedule"] as? [String: Any],
          scheduleModule["status"] as? String != "error",
          let schedule = scheduleModule["data"] else {
      throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "组件快照缺少生效课表或课表读取失败"])
    }
    let scheduleData = try JSONSerialization.data(withJSONObject: schedule)
    let courses = try JSONDecoder().decode([WidgetCourseTimelineItem].self, from: scheduleData)
    try storeSchedule(courses, configuration: configuration, defaults: defaults)
    defaults.set(data, forKey: "widgetSnapshotPayload")
    defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: "widgetUpdatedAtEpochMillis")
    if let grades = moduleList(modules, name: "grades") {
      let gradeItems = grades.map { grade in
        [
          "name": grade["courseName"] as? String ?? "课程",
          "score": grade["score"] as? String ?? "-",
          "credit": grade["credit"] as? String ?? "",
          "gpa": grade["gradePoint"] as? String ?? "",
        ]
      }
      defaults.set(jsonString(gradeItems), forKey: "gradeItemsJson")
      defaults.set("\(gradeItems.count)", forKey: "gradeCount")
      let gradePoints = grades.compactMap { Double($0["gradePoint"] as? String ?? "") }
      if !gradePoints.isEmpty {
        defaults.set(String(format: "%.2f", gradePoints.reduce(0, +) / Double(gradePoints.count)), forKey: "gradeGpa")
      }
      let scores = grades.compactMap { Double($0["score"] as? String ?? "") }
      if !scores.isEmpty {
        defaults.set(String(format: "%.1f", scores.reduce(0, +) / Double(scores.count)), forKey: "gradeAverage")
      }
    }
    if let exams = moduleList(modules, name: "exams") {
      let examItems = exams.map { exam in
        [
          "name": exam["courseName"] as? String ?? "考试",
          "date": exam["date"] as? String ?? "",
          "time": exam["time"] as? String ?? "",
          "location": exam["location"] as? String ?? "",
          "days": 9999,
          "urgent": false,
        ] as [String: Any]
      }
      defaults.set(jsonString(examItems), forKey: "examItemsJson")
      defaults.set("\(examItems.count)", forKey: "examCount")
    }
    if let progress = moduleObject(modules, name: "progress"), let items = progress["items"] as? [[String: Any]] {
      defaults.set(jsonString(items), forKey: "progressItemsJson")
    }
    if let ecard = moduleObject(modules, name: "ecard") {
      defaults.set(ecard["powerText"] as? String ?? "-", forKey: "utilityElectricity")
      defaults.set(ecard["coldWaterText"] as? String ?? "-", forKey: "utilityColdWater")
      defaults.set(ecard["hotWaterText"] as? String ?? "-", forKey: "utilityHotWater")
      defaults.set(ecard["roomDisplay"] as? String ?? "", forKey: "utilityRoomInfo")
      defaults.set(ecard["status"] as? String == "ok", forKey: "utilityIsBound")
    }
    return true
  }

  private static func moduleList(_ modules: [String: Any], name: String) -> [[String: Any]]? {
    guard let module = modules[name] as? [String: Any], module["status"] as? String != "error" else { return nil }
    return module["data"] as? [[String: Any]]
  }

  private static func moduleObject(_ modules: [String: Any], name: String) -> [String: Any]? {
    guard let module = modules[name] as? [String: Any], module["status"] as? String != "error" else { return nil }
    return module["data"] as? [String: Any]
  }

  private static func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  static func storeSchedule(
    _ courses: [WidgetCourseTimelineItem],
    configuration: Configuration,
    defaults: UserDefaults
  ) throws {
    let now = Date()
    let calendar = Calendar.current
    let firstWeek = Date(timeIntervalSince1970: TimeInterval(configuration.firstWeekStartEpochMillis) / 1_000)
    let projected = try WidgetScheduleProjection.make(courses: courses, firstWeekStart: firstWeek, now: now, calendar: calendar)
    defaults.set(String(decoding: try JSONEncoder().encode(courses), as: UTF8.self), forKey: "effectiveCoursesJson")
    defaults.set(String(decoding: try JSONEncoder().encode(projected.weekly), as: UTF8.self), forKey: "weeklyCoursesJson")
    defaults.set(String(decoding: try JSONEncoder().encode(projected.today), as: UTF8.self), forKey: "todayCoursesJson")
    defaults.set(projected.today.isEmpty ? "今日无课" : "今日 \(projected.today.count) 节课", forKey: "todayTitle")
    defaults.set("第\(projected.week)周 · \(projected.today.count) 节课", forKey: "todayMeta")
    defaults.set(projected.today.map { "\($0.time) \($0.name)" }, forKey: "todayItems")
    let next = projected.next
    defaults.set(next.title, forKey: "nextTitle")
    defaults.set(next.time, forKey: "nextTime")
    defaults.set(next.location, forKey: "nextClassroom")
    defaults.set(next.teacher, forKey: "nextTeacher")
    defaults.set(next.status, forKey: "nextStatus")
    defaults.set(next.status == "none" ? "暂无待上课程" : "\(next.time) · \(next.location)", forKey: "nextMeta")
    defaults.set(next.status == "ongoing" ? "进行中" : next.status == "upcoming" ? "待开始" : "点击查看课表", forKey: "nextDetail")
    defaults.set(Int64((next.start?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextStartEpochMillis")
    defaults.set(Int64((next.end?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextEndEpochMillis")
  }

  private static func projectCachedSchedule(configuration: Configuration, defaults: UserDefaults) throws {
    guard let raw = defaults.string(forKey: "effectiveCoursesJson"), let data = raw.data(using: .utf8) else {
      throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "桌面组件缺少生效课程缓存"])
    }
    try storeSchedule(JSONDecoder().decode([WidgetCourseTimelineItem].self, from: data), configuration: configuration, defaults: defaults)
  }

}
