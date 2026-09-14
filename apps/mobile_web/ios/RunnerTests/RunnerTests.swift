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
      ongoing: false
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

}
