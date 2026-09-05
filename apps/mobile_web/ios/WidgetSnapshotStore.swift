import Foundation

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
    firstWeekStartEpochMillis: Int64
  ) -> Bool {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
    let configuration = Configuration(
      baseURL: baseURL,
      sessionID: sessionID,
      year: year,
      term: term,
      firstWeekStartEpochMillis: firstWeekStartEpochMillis
    )
    guard let data = try? JSONEncoder().encode(configuration) else { return false }
    defaults.set(data, forKey: configurationKey)
    return true
  }

  static func configuration() -> Configuration? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let data = defaults.data(forKey: configurationKey) else { return nil }
    return try? JSONDecoder().decode(Configuration.self, from: data)
  }

  static func clearConfiguration() {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    defaults.removeObject(forKey: configurationKey)
    defaults.removeObject(forKey: etagKey)
    defaults.removeObject(forKey: lastFetchKey)
  }

  static func refreshIfNeeded(completion: @escaping () -> Void) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let configuration = configuration() else {
      completion()
      return
    }
    let now = Date()
    if let lastFetch = defaults.object(forKey: lastFetchKey) as? Date,
       now.timeIntervalSince(lastFetch) < minimumFetchInterval {
      completion()
      return
    }
    guard var components = URLComponents(
      string: "\(configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/widget-snapshot"
    ) else {
      completion()
      return
    }
    components.queryItems = [
      URLQueryItem(name: "year", value: String(configuration.year)),
      URLQueryItem(name: "term", value: String(configuration.term)),
      URLQueryItem(name: "week", value: String(configuration.currentWeek(now: now))),
    ]
    guard let url = components.url else {
      completion()
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(configuration.sessionID, forHTTPHeaderField: "X-Session-Id")
    if let etag = defaults.string(forKey: etagKey) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { completion() }
      guard let response = response as? HTTPURLResponse else { return }
      if response.statusCode == 401 {
        clearConfiguration()
        return
      }
      guard response.statusCode == 200 || response.statusCode == 304 else { return }
      defaults.set(now, forKey: lastFetchKey)
      if response.statusCode == 304 { return }
      guard let data, storeSnapshot(data, currentWeek: configuration.currentWeek(now: now), defaults: defaults) else {
        return
      }
      if let etag = response.value(forHTTPHeaderField: "ETag") {
        defaults.set(etag, forKey: etagKey)
      }
    }.resume()
  }

  private static func storeSnapshot(_ data: Data, currentWeek: Int, defaults: UserDefaults) -> Bool {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modules = payload["modules"] as? [String: Any] else { return false }
    defaults.set(data, forKey: "widgetSnapshotPayload")
    defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: "widgetUpdatedAtEpochMillis")
    if let schedule = moduleList(modules, name: "schedule") {
      storeWeeklySchedule(schedule, currentWeek: currentWeek, defaults: defaults)
      storeTodaySchedule(schedule, currentWeek: currentWeek, defaults: defaults)
    }
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

  private static func storeTodaySchedule(_ courses: [[String: Any]], currentWeek: Int, defaults: UserDefaults) {
    let calendar = Calendar.current
    let now = Date()
    let weekday = ((calendar.component(.weekday, from: now) + 5) % 7) + 1
    let today = courses.compactMap { course -> [String: Any]? in
      guard intValue(course["weekday"]) == weekday,
            let startSection = intValue(course["startSection"]),
            let endSection = intValue(course["endSection"]),
            startSection >= 1, endSection <= sectionTimes.count,
            occursInWeek(course["weeks"] as? String ?? "", currentWeek: currentWeek) else { return nil }
      let startTime = sectionTimes[startSection - 1].0
      let endTime = sectionTimes[endSection - 1].1
      let start = dateToday(startTime, calendar: calendar, now: now)
      let end = dateToday(endTime, calendar: calendar, now: now)
      let source = (course["courseId"] as? String ?? course["kch_id"] as? String ?? course["courseCode"] as? String ?? course["name"] as? String ?? "课程")
      return [
        "itemKey": "\(source):\(weekday):\(startSection)",
        "weekday": weekday,
        "startSection": startSection,
        "time": startTime,
        "name": course["name"] as? String ?? "课程",
        "info": [course["classroom"] as? String, course["teacher"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
        "ongoing": start <= now && now < end,
        "start": start,
        "end": end,
      ]
    }.sorted { ($0["start"] as? Date ?? now) < ($1["start"] as? Date ?? now) }
    let visibleCourses = today.map { course in
      ["itemKey": course["itemKey"] as? String ?? "", "week": currentWeek, "weekday": course["weekday"] as? Int ?? weekday, "startSection": course["startSection"] as? Int ?? 0, "time": course["time"] as? String ?? "", "name": course["name"] as? String ?? "课程", "info": course["info"] as? String ?? "", "ongoing": course["ongoing"] as? Bool ?? false]
    }
    let tomorrowWeekday = weekday == 7 ? 1 : weekday + 1
    let hasTomorrow = courses.contains { course in
      intValue(course["weekday"]) == tomorrowWeekday &&
        occursInWeek(course["weeks"] as? String ?? "", currentWeek: currentWeek)
    }
    let noTodayOrTomorrow = today.isEmpty && !hasTomorrow
    let next = today.first { ($0["end"] as? Date ?? now) > now }
    defaults.set(jsonString(visibleCourses), forKey: "todayCoursesJson")
    defaults.set(today.map { "\($0["time"] as? String ?? "") \($0["name"] as? String ?? "课程")" }, forKey: "todayItems")
    defaults.set(today.isEmpty ? "今日无课" : "今日 \(today.count) 节课", forKey: "todayTitle")
    defaults.set("第\(currentWeek)周 · \(today.count) 节课", forKey: "todayMeta")
    defaults.set(noTodayOrTomorrow ? "今明无课" : (next?["name"] as? String ?? "暂无下一节课"), forKey: "nextTitle")
    defaults.set(noTodayOrTomorrow ? "" : (next?["time"] as? String ?? ""), forKey: "nextTime")
    defaults.set(noTodayOrTomorrow ? "" : (next?["info"] as? String ?? ""), forKey: "nextClassroom")
    defaults.set(noTodayOrTomorrow || next == nil ? "none" : ((next?["ongoing"] as? Bool ?? false) ? "ongoing" : "upcoming"), forKey: "nextStatus")
    defaults.set(noTodayOrTomorrow ? 0 : Int64(((next?["start"] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextStartEpochMillis")
    defaults.set(noTodayOrTomorrow ? 0 : Int64(((next?["end"] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextEndEpochMillis")
  }

  private static func storeWeeklySchedule(_ courses: [[String: Any]], currentWeek: Int, defaults: UserDefaults) {
    let now = Date()
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: now)
    let calendarWeekday = calendar.component(.weekday, from: now)
    let mondayOffset = calendarWeekday == 1 ? -6 : 2 - calendarWeekday
    let monday = calendar.date(byAdding: .day, value: mondayOffset, to: todayStart) ?? todayStart
    let values = courses.compactMap { course -> [String: Any]? in
      guard let weekday = intValue(course["weekday"]), (1...7).contains(weekday),
            let startSection = intValue(course["startSection"]), startSection >= 1,
            let endSection = intValue(course["endSection"] ?? course["startSection"]), endSection >= startSection,
            endSection <= sectionTimes.count,
            occursInWeek(course["weeks"] as? String ?? "", currentWeek: currentWeek) else { return nil }
      let startTime = sectionTimes[startSection - 1].0
      let endTime = sectionTimes[endSection - 1].1
      let itemKey = (course["courseId"] as? String ?? course["kch_id"] as? String ?? course["courseCode"] as? String ?? course["name"] as? String ?? "课程") + ":\(weekday):\(startSection)"
      let dayOffset = weekday - 1
      let start = dateByAddingDays(dayOffset, time: startTime, calendar: calendar, baseDate: monday)
      let end = dateByAddingDays(dayOffset, time: endTime, calendar: calendar, baseDate: monday)
      return [
        "itemKey": itemKey,
        "week": currentWeek,
        "weekday": weekday,
        "startSection": startSection,
        "endSection": endSection,
        "time": "\(startTime)-\(endTime)",
        "name": course["name"] as? String ?? "课程",
        "classroom": course["classroom"] as? String ?? "",
        "teacher": course["teacher"] as? String ?? "",
        "ongoing": Calendar.current.isDate(start, inSameDayAs: now) && start <= now && now < end,
      ]
    }.sorted {
      let leftDay = intValue($0["weekday"]) ?? 0
      let rightDay = intValue($1["weekday"]) ?? 0
      if leftDay != rightDay { return leftDay < rightDay }
      return (intValue($0["startSection"]) ?? 0) < (intValue($1["startSection"]) ?? 0)
    }
    defaults.set(jsonString(values), forKey: "weeklyCoursesJson")
  }

  private static func dateByAddingDays(_ days: Int, time: String, calendar: Calendar, baseDate: Date) -> Date {
    let date = calendar.date(byAdding: .day, value: days, to: baseDate) ?? baseDate
    let parts = time.split(separator: ":").compactMap { Int($0) }
    return calendar.date(bySettingHour: parts.first ?? 0, minute: parts.dropFirst().first ?? 0, second: 0, of: date) ?? date
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }

  private static func occursInWeek(_ spec: String, currentWeek: Int) -> Bool {
    if spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    if spec.contains("单") && currentWeek % 2 == 0 { return false }
    if spec.contains("双") && currentWeek % 2 != 0 { return false }
    let values = spec.split { !$0.isNumber && $0 != "-" && $0 != "~" && $0 != "至" }.map(String.init)
    for value in values {
      let bounds = value.split(whereSeparator: { $0 == "-" || $0 == "~" || $0 == "至" }).compactMap { Int($0) }
      if bounds.count == 2 && currentWeek >= bounds[0] && currentWeek <= bounds[1] { return true }
      if bounds.count == 1 && currentWeek == bounds[0] { return true }
    }
    return false
  }

  private static func dateToday(_ time: String, calendar: Calendar, now: Date) -> Date {
    let values = time.split(separator: ":").compactMap { Int($0) }
    guard values.count == 2 else { return now }
    return calendar.date(bySettingHour: values[0], minute: values[1], second: 0, of: now) ?? now
  }
}
