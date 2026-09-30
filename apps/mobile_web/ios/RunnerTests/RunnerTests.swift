import Foundation
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0) ?? value.timeZone
    return value
  }

  private func course(
    _ key: String,
    weekday: Int,
    startSection: Int,
    endSection: Int,
    time: String,
    name: String
  ) -> WidgetCourseTimelineItem {
    WidgetCourseTimelineItem(
      itemKey: key,
      week: 1,
      weekday: weekday,
      startSection: startSection,
      endSection: endSection,
      time: time,
      name: name,
      classroom: "A101",
      teacher: "张老师",
      ongoing: false,
      date: nil
    )
  }

  func testStateChangesAtCourseBoundaries() {
    let first = course("first", weekday: 1, startSection: 1, endSection: 1, time: "09:00-09:40", name: "第一节")
    let second = course("second", weekday: 1, startSection: 2, endSection: 2, time: "09:40-10:20", name: "第二节")
    let monday = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: 14))!

    let before = monday.addingTimeInterval(8 * 60 * 60)
    XCTAssertEqual(WidgetNextClassTimeline.state(at: before, courses: [first, second], calendar: calendar).title, "第一节")
    XCTAssertEqual(WidgetNextClassTimeline.state(at: monday.addingTimeInterval(9 * 60 * 60 + 1), courses: [first, second], calendar: calendar).status, "ongoing")
    XCTAssertEqual(WidgetNextClassTimeline.state(at: monday.addingTimeInterval(9 * 60 * 60 + 40 * 60), courses: [first, second], calendar: calendar).title, "第二节")
  }

  func testTransitionDatesDeduplicateAdjacentCourseBoundary() {
    let first = course("first", weekday: 1, startSection: 1, endSection: 1, time: "09:00-09:40", name: "第一节")
    let second = course("second", weekday: 1, startSection: 2, endSection: 2, time: "09:40-10:20", name: "第二节")
    let monday = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: 14))!
    let dates = WidgetNextClassTimeline.transitionDates(
      after: monday.addingTimeInterval(8 * 60 * 60),
      courses: [first, second],
      calendar: calendar
    )

    XCTAssertEqual(dates.count, 3)
    XCTAssertEqual(dates[1], monday.addingTimeInterval(9 * 60 * 60 + 40 * 60))
  }

  func testLastCourseAndNoCourseDayReturnNone() {
    let first = course("first", weekday: 1, startSection: 1, endSection: 1, time: "09:00-09:40", name: "第一节")
    let monday = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: 14))!
    let state = WidgetNextClassTimeline.state(
      at: monday.addingTimeInterval(10 * 60 * 60),
      courses: [first],
      calendar: calendar
    )

    XCTAssertEqual(state, WidgetNextClassState.none)
  }

  func testNextDayCourseIsSelectedWithoutOpeningTheApp() {
    let nextDay = course("next-day", weekday: 2, startSection: 1, endSection: 1, time: "09:00-09:40", name: "明日课程")
    let monday = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: 14))!
    let state = WidgetNextClassTimeline.state(
      at: monday.addingTimeInterval(18 * 60 * 60),
      courses: [nextDay],
      calendar: calendar
    )

    XCTAssertEqual(state.title, "明日课程")
    XCTAssertEqual(state.status, "upcoming")
  }

  func testDatedWidgetScheduleCrossesWeeksWithoutRecyclingExpiredCourses() throws {
    let data = Data("""
      [{"itemKey":"past","date":"2026-09-07","week":1,"weekday":1,"startSection":1,"endSection":2,"time":"09:00-10:20","name":"数学","classroom":"A101","teacher":"老师","ongoing":false},
       {"itemKey":"moved","date":"2026-09-14","week":2,"weekday":1,"startSection":1,"endSection":2,"time":"09:00-10:20","name":"数学","classroom":"A101","teacher":"老师","ongoing":false}]
      """.utf8)
    let courses = try JSONDecoder().decode([WidgetCourseTimelineItem].self, from: data)
    let first = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
    let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 20))!
    let before = try WidgetScheduleProjection.make(courses: courses, firstWeekStart: first, now: sunday, calendar: calendar)
    XCTAssertEqual(before.weekly.map { $0.itemKey }, ["past"])
    XCTAssertTrue(before.today.isEmpty)
    XCTAssertEqual(before.next.status, "upcoming")
    XCTAssertTrue(before.next.time.hasPrefix("2026-09-14"))
    let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 10))!
    let ongoing = try WidgetScheduleProjection.make(courses: courses, firstWeekStart: first, now: monday, calendar: calendar)
    XCTAssertEqual(ongoing.week, 2)
    XCTAssertEqual(ongoing.today.count, 1)
    XCTAssertEqual(ongoing.next.status, "ongoing")
    let nextWeek = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 8))!
    let expired = try WidgetScheduleProjection.make(courses: courses, firstWeekStart: first, now: nextWeek, calendar: calendar)
    XCTAssertTrue(expired.weekly.isEmpty)
    XCTAssertEqual(expired.next, .none)
  }

  func testWidgetProjectionHonorsEmptyScheduleAndRejectsUndatedData() throws {
    let first = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
    let projection = try WidgetScheduleProjection.make(courses: [], firstWeekStart: first, now: first, calendar: calendar)
    XCTAssertTrue(projection.weekly.isEmpty)
    XCTAssertTrue(projection.today.isEmpty)
    XCTAssertEqual(projection.next, .none)
    let undated = course("old", weekday: 1, startSection: 1, endSection: 2, time: "09:00-10:20", name: "原始周课")
    XCTAssertThrowsError(try WidgetScheduleProjection.make(courses: [undated], firstWeekStart: first, now: first, calendar: calendar))
  }

  func testLateResponsesCannotWriteOrClearReplacedWidgetSession() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { XCTFail("清理组件测试目录失败：\(error.localizedDescription)") }
    }
    let lockURL = directory.appendingPathComponent("refresh.lock")
    let generationURL = directory.appendingPathComponent("generation")
    let snapshotURL = directory.appendingPathComponent("snapshot")
    try WidgetStorageTransactions.access(lockURL: lockURL) {
      try Data("new-request".utf8).write(to: generationURL, options: .atomic)
      try Data("new-account".utf8).write(to: snapshotURL, options: .atomic)
    }
    XCTAssertFalse(try WidgetStorageTransactions.commit(
      lockURL: lockURL, generationURL: generationURL, requestedGeneration: "old-request"
    ) {
      try Data("old-account".utf8).write(to: snapshotURL)
      return true
    })
    XCTAssertFalse(try WidgetStorageTransactions.commit(
      lockURL: lockURL, generationURL: generationURL, requestedGeneration: "old-request"
    ) {
      try FileManager.default.removeItem(at: generationURL)
      return true
    })
    XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), "new-account")
    XCTAssertEqual(try String(contentsOf: generationURL, encoding: .utf8), "new-request")
  }

  func testLogoutAndSameAccountUpdateInvalidateEarlierWidgetResponse() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { XCTFail("清理组件测试目录失败：\(error.localizedDescription)") }
    }
    let lockURL = directory.appendingPathComponent("refresh.lock")
    let generationURL = directory.appendingPathComponent("generation")
    try Data("first-visit".utf8).write(to: generationURL)
    XCTAssertTrue(try WidgetStorageTransactions.commit(
      lockURL: lockURL, generationURL: generationURL, requestedGeneration: "first-visit"
    ) { true })
    try WidgetStorageTransactions.access(lockURL: lockURL) {
      try Data("second-visit".utf8).write(to: generationURL, options: .atomic)
    }
    XCTAssertFalse(try WidgetStorageTransactions.commit(
      lockURL: lockURL, generationURL: generationURL, requestedGeneration: "first-visit"
    ) { XCTFail("过期响应不应执行存储"); return true })
    try WidgetStorageTransactions.access(lockURL: lockURL) {
      try FileManager.default.removeItem(at: generationURL)
    }
    XCTAssertFalse(try WidgetStorageTransactions.commit(
      lockURL: lockURL, generationURL: generationURL, requestedGeneration: "second-visit"
    ) { XCTFail("退出后不应执行存储"); return true })
  }

}
