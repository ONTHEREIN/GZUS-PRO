import Flutter
import UIKit
import CoreLocation
import BackgroundTasks
import EventKit
import ActivityKit
import Security
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CLLocationManagerDelegate {
  private let homeWidgetsChannel = "cn.gzus.pro/home_widgets"
  private let homeWidgetsAppGroup = "group.cn.gzus.pro.6772c5tf6c"
  private let nextClassHomeScreenWidgetKind = "OneGzusNextClassHomeScreen"
  private let nextClassLockScreenWidgetKind = "OneGzusNextClassLockScreen"
  private let todayCoursesWidgetKind = "OneGzusTodayCourses"
  private let examCountdownWidgetKind = "OneGzusExamCountdown"
  private let gradesWidgetKind = "OneGzusGrades"
  private let utilitiesWidgetKind = "OneGzusUtilities"
  private let progressWidgetKind = "OneGzusProgress"
  private let pendingWidgetTabDefaultsKey = "pending_widget_tab"
  private let widgetRefreshTaskIdentifier = "cn.gzus.pro.widget-refresh"
  private let widgetRefreshConfigDefaultsKey = "widget_refresh_configuration"
  private let widgetRefreshKeychainService = "cn.gzus.pro.widget-refresh"
  private let widgetRefreshKeychainAccount = "session-id"
  private let widgetRefreshEtagDefaultsKey = "widget_refresh_etag"
  private let liquidGlassChannelName = "cn.gzus.pro/liquid-glass"
  private let permissionsChannelName = "cn.gzus.pro/permissions"
  private let locationChannelName = "cn.gzus.pro/location"
  private let pushChannelName = "cn.gzus.pro/push"
  private let calendarChannelName = "cn.gzus.pro/calendar"
  private let remotePushTokenDefaultsKey = "remote_push_token"
  private let notificationOpenDefaultsKey = "notification_open_extras"
  /// 课程节次时间表（与 lib/schedule_utils.dart 的 scheduleTimes 保持一致）
  private let widgetSectionTimes: [(String, String)] = [
    ("09:00", "09:40"),
    ("09:40", "10:20"),
    ("10:40", "11:20"),
    ("11:20", "12:00"),
    ("12:30", "13:10"),
    ("13:10", "13:50"),
    ("14:00", "14:40"),
    ("14:40", "15:20"),
    ("15:30", "16:10"),
    ("16:10", "16:50"),
    ("17:00", "17:40"),
    ("17:40", "18:20"),
    ("19:00", "19:40"),
    ("19:40", "20:20"),
    ("20:30", "21:10"),
    ("21:10", "21:50"),
  ]
  private var liquidGlassChannel: FlutterMethodChannel?
  private var homeWidgets: FlutterMethodChannel?
  private weak var nativeLiquidTabBar: NativeLiquidTabBarView?
  private var pendingRemotePushTokenResult: FlutterResult?
  private var locationManager: CLLocationManager?
  private var pendingLocationResult: FlutterResult?
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ShiplyManager.shared().initializeSDK()
    registerWidgetRefreshTask()
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      cacheNotificationOpen(userInfo)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerWidgetRefreshTask() {
    guard #available(iOS 13.0, *) else { return }
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: widgetRefreshTaskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let task = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleWidgetRefresh(task)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerLiquidGlass(with: engineBridge)

    // 隐式 Flutter 引擎完成初始化时，FlutterViewController 可能尚未创建。
    // 应通过引擎桥接器取得消息通道，不能依赖 window.rootViewController。
    let messenger = engineBridge.applicationRegistrar.messenger()
    ShiplyManager.shared().register(with: messenger)
    let homeWidgets = FlutterMethodChannel(name: homeWidgetsChannel, binaryMessenger: messenger)
    homeWidgets.setMethodCallHandler { [weak self] call, result in
      self?.handleHomeWidgetMethod(call: call, result: result)
    }
    self.homeWidgets = homeWidgets
    let permissions = FlutterMethodChannel(name: permissionsChannelName, binaryMessenger: messenger)
    permissions.setMethodCallHandler { [weak self] call, result in
      self?.handlePermissionMethod(call: call, result: result)
    }
    let location = FlutterMethodChannel(name: locationChannelName, binaryMessenger: messenger)
    location.setMethodCallHandler { [weak self] call, result in
      self?.handleLocationMethod(call: call, result: result)
    }
    let push = FlutterMethodChannel(name: pushChannelName, binaryMessenger: messenger)
    push.setMethodCallHandler { [weak self] call, result in
      self?.handlePushMethod(call: call, result: result)
    }
    let calendar = FlutterMethodChannel(name: calendarChannelName, binaryMessenger: messenger)
    calendar.setMethodCallHandler { [weak self] call, result in
      self?.handleCalendarMethod(call: call, result: result)
    }
    if #available(iOS 16.1, *) {
      LiveActivityManager.shared.register(with: messenger)
    }
  }

  private func handleLocationMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let manager = locationManager ?? {
      let value = CLLocationManager()
      value.delegate = self
      locationManager = value
      return value
    }()
    switch call.method {
    case "requestLocationPermission":
      manager.requestWhenInUseAuthorization()
      result(true)
    case "getCoarseLocation":
      switch CLLocationManager.authorizationStatus() {
      case .authorizedAlways, .authorizedWhenInUse:
        pendingLocationResult = result
        manager.requestLocation()
      case .notDetermined:
        pendingLocationResult = result
        manager.requestWhenInUseAuthorization()
      case .denied, .restricted:
        result(FlutterError(code: "LOCATION_PERMISSION_DENIED", message: "定位权限未授予", details: nil))
      @unknown default:
        result(FlutterError(code: "LOCATION_ERROR", message: "无法确定定位权限状态", details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard pendingLocationResult != nil else { return }
    switch CLLocationManager.authorizationStatus() {
    case .authorizedAlways, .authorizedWhenInUse:
      manager.requestLocation()
    case .denied, .restricted:
      pendingLocationResult?(FlutterError(code: "LOCATION_PERMISSION_DENIED", message: "定位权限未授予", details: nil))
      pendingLocationResult = nil
    default:
      break
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    pendingLocationResult?(["lat": location.coordinate.latitude, "lon": location.coordinate.longitude])
    pendingLocationResult = nil
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    pendingLocationResult?(FlutterError(code: "LOCATION_ERROR", message: "获取定位失败: \(error.localizedDescription)", details: nil))
    pendingLocationResult = nil
  }

  private func handlePermissionMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkNotificationPermission":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        result(self.isNotificationAuthorized(settings))
      }
    case "requestNotificationPermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
        granted, error in
        if let error {
          result(FlutterError(
            code: "NOTIFICATION_PERMISSION_FAILED",
            message: "请求 iOS 通知权限失败: \(error.localizedDescription)",
            details: nil
          ))
          return
        }
        result(granted)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handlePushMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "consumeNotificationOpen":
      let extras = UserDefaults.standard.dictionary(forKey: notificationOpenDefaultsKey)
      UserDefaults.standard.removeObject(forKey: notificationOpenDefaultsKey)
      result(extras)
    case "getRemotePushToken":
      result(UserDefaults.standard.string(forKey: remotePushTokenDefaultsKey))
    case "requestRemotePushToken":
      if let token = UserDefaults.standard.string(forKey: remotePushTokenDefaultsKey), !token.isEmpty {
        result(token)
        return
      }
      if pendingRemotePushTokenResult != nil {
        result(FlutterError(
          code: "REMOTE_PUSH_REGISTRATION_IN_PROGRESS",
          message: "iOS 远程推送注册正在进行中。",
          details: nil
        ))
        return
      }
      pendingRemotePushTokenResult = result
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleCalendarMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "importEvents" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
          let events = arguments["events"] as? [[String: Any]],
          !events.isEmpty else {
      result(0)
      return
    }
    importEventsToCalendar(events, result: result)
  }

  private func importEventsToCalendar(
    _ events: [[String: Any]],
    result: @escaping FlutterResult
  ) {
    let store = EKEventStore()
    if #available(iOS 17.0, *) {
      switch EKEventStore.authorizationStatus(for: .event) {
      case .fullAccess, .writeOnly:
        insertCalendarEvents(events, store: store, result: result)
      case .notDetermined:
        store.requestFullAccessToEvents { [weak self] granted, error in
          DispatchQueue.main.async {
            guard let self else {
              result(false)
              return
            }
            if granted {
              self.insertCalendarEvents(events, store: store, result: result)
            } else {
              result(FlutterError(
                code: "CALENDAR_PERMISSION_DENIED",
                message: "未授予日历权限，无法导入",
                details: error?.localizedDescription
              ))
            }
          }
        }
      default:
        result(FlutterError(
          code: "CALENDAR_PERMISSION_DENIED",
          message: "未授予日历权限，无法导入",
          details: nil
        ))
      }
    } else {
      switch EKEventStore.authorizationStatus(for: .event) {
      case .authorized:
        insertCalendarEvents(events, store: store, result: result)
      case .notDetermined:
        store.requestAccess(to: .event) { [weak self] granted, error in
          DispatchQueue.main.async {
            guard let self else {
              result(false)
              return
            }
            if granted {
              self.insertCalendarEvents(events, store: store, result: result)
            } else {
              result(FlutterError(
                code: "CALENDAR_PERMISSION_DENIED",
                message: "未授予日历权限，无法导入",
                details: error?.localizedDescription
              ))
            }
          }
        }
      default:
        result(FlutterError(
          code: "CALENDAR_PERMISSION_DENIED",
          message: "未授予日历权限，无法导入",
          details: nil
        ))
      }
    }
  }

  private func insertCalendarEvents(
    _ events: [[String: Any]],
    store: EKEventStore,
    result: @escaping FlutterResult
  ) {
    guard let targetCalendar = store.defaultCalendarForNewEvents else {
      result(FlutterError(
        code: "NO_CALENDAR",
        message: "设备上没有可写入的系统日历",
        details: nil
      ))
      return
    }
    var added = 0
    var updated = 0
    var skipped = 0
    var lastError: String?
    for raw in events {
      guard let start = (raw["startMillis"] as? NSNumber)?.doubleValue,
            let end = (raw["endMillis"] as? NSNumber)?.doubleValue else {
        skipped += 1
        continue
      }
      guard let sourceId = raw["sourceId"] as? String, !sourceId.isEmpty else {
        skipped += 1
        continue
      }
      let marker = "OneGZUS-ID:\(sourceId)"
      let startDate = Date(timeIntervalSince1970: start / 1000)
      let endDate = Date(timeIntervalSince1970: end / 1000)
      let predicate = store.predicateForEvents(
        withStart: startDate.addingTimeInterval(-86400),
        end: endDate.addingTimeInterval(86400),
        calendars: [targetCalendar]
      )
      let existing = store.events(matching: predicate).first {
        $0.notes?.contains(marker) == true
      }
      let event = EKEvent(eventStore: store)
      event.title = raw["title"] as? String ?? "软帮手日程"
      event.startDate = startDate
      event.endDate = endDate
      event.location = raw["location"] as? String
      let description = raw["description"] as? String
      event.notes = [description, marker].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
      event.calendar = targetCalendar
      do {
        if let existing {
          existing.title = event.title
          existing.startDate = event.startDate
          existing.endDate = event.endDate
          existing.location = event.location
          existing.notes = event.notes
          try store.save(existing, span: .thisEvent, commit: true)
          updated += 1
        } else {
          try store.save(event, span: .thisEvent, commit: true)
          added += 1
        }
      } catch {
        lastError = error.localizedDescription
      }
    }
    if added + updated + skipped > 0 {
      result(["added": added, "updated": updated, "skipped": skipped])
    } else {
      result(FlutterError(
        code: "CALENDAR_SAVE_FAILED",
        message: lastError ?? "未能写入系统日历",
        details: nil
      ))
    }
  }

  private func isNotificationAuthorized(_ settings: UNNotificationSettings) -> Bool {
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return true
    case .denied, .notDetermined:
      return false
    @unknown default:
      return false
    }
  }

  private func cacheNotificationOpen(_ userInfo: [AnyHashable: Any]) {
    guard let extras = userInfo["extras"] as? [String: Any] else {
      return
    }
    let supportedExtras = extras.compactMapValues { value -> Any? in
      if value is String || value is NSNumber {
        return value
      }
      return nil
    }
    guard !supportedExtras.isEmpty else {
      return
    }
    UserDefaults.standard.set(supportedExtras, forKey: notificationOpenDefaultsKey)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(token, forKey: remotePushTokenDefaultsKey)
    pendingRemotePushTokenResult?(token)
    pendingRemotePushTokenResult = nil
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pendingRemotePushTokenResult?(FlutterError(
      code: "REMOTE_PUSH_REGISTRATION_FAILED",
      message: "iOS 远程推送注册失败: \(error.localizedDescription)",
      details: nil
    ))
    pendingRemotePushTokenResult = nil
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    cacheNotificationOpen(response.notification.request.content.userInfo)
    completionHandler()
  }

  private func handleHomeWidgetMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "consumeInitialTab" {
      let tab = UserDefaults.standard.string(forKey: pendingWidgetTabDefaultsKey)
      UserDefaults.standard.removeObject(forKey: pendingWidgetTabDefaultsKey)
      result(tab)
      return
    }
    if call.method == "clearRefreshConfiguration" {
      clearWidgetRefreshConfiguration()
      result(true)
      return
    }
    if call.method == "replaceRefreshSession" {
      guard let values = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "组件刷新会话参数无效", details: nil))
        return
      }
      configureWidgetRefresh(values: values, preservePeriod: true, result: result)
      return
    }
    guard call.method == "update" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let values = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Widget data must be a map.", details: nil))
      return
    }
    guard #available(iOS 14.0, *) else {
      result(true)
      return
    }
    guard let defaults = UserDefaults(suiteName: homeWidgetsAppGroup) else {
      result(FlutterError(code: "APP_GROUP_UNAVAILABLE", message: "The OneGzus widget app group is unavailable.", details: nil))
      return
    }

    let stringKeys = [
      "nextTitle", "nextMeta", "nextDetail", "nextClassroom", "nextTeacher", "nextStatus", "nextTime",
      "todayTitle", "todayMeta", "todayItems", "todayCoursesJson",
      "utilityTitle", "utilityMeta", "utilityDetail", "utilityColdWater", "utilityHotWater", "utilityElectricity", "utilityRoomInfo",
      "progressTitle", "progressMeta", "progressDetail", "progressItemsJson",
      "examCount", "examItemsJson", "gradeGpa", "gradeAverage", "gradeCount", "gradeItemsJson"
    ]
    var changedKinds = Set<String>()
    for key in stringKeys {
      if defaults.string(forKey: key) != (values[key] as? String ?? "") {
        changedKinds.formUnion(widgetKinds(forValueKey: key))
      }
      defaults.set(values[key] as? String ?? "", forKey: key)
    }
    let numberKeys = [
      "nextStartEpochMillis", "nextEndEpochMillis", "widgetUpdatedAtEpochMillis"
    ]
    for key in numberKeys {
      let value = (values[key] as? NSNumber)?.int64Value ?? 0
      if defaults.object(forKey: key) as? Int64 != value {
        changedKinds.formUnion(widgetKinds(forValueKey: key))
      }
      defaults.set(value, forKey: key)
    }
    let boolKeys = ["utilityIsBound", "utilityLowPower"]
    for key in boolKeys {
      let value = values[key] as? Bool ?? false
      if defaults.bool(forKey: key) != value {
        changedKinds.formUnion(widgetKinds(forValueKey: key))
      }
      defaults.set(value, forKey: key)
    }
    reloadWidgetTimelines(changedKinds)
    configureWidgetRefresh(values: values, preservePeriod: false, result: result)
  }

  private func configureWidgetRefresh(
    values: [String: Any],
    preservePeriod: Bool,
    result: @escaping FlutterResult
  ) {
    guard let baseUrl = values["widgetApiBaseUrl"] as? String, !baseUrl.isEmpty,
          let sessionId = values["widgetSessionId"] as? String, !sessionId.isEmpty else {
      if preservePeriod {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "组件刷新会话参数不完整", details: nil))
      } else {
        result(true)
      }
      return
    }
    let defaults = UserDefaults.standard
    let old = defaults.dictionary(forKey: widgetRefreshConfigDefaultsKey) ?? [:]
    let year = values["widgetYear"] as? Int ?? old["year"] as? Int
    let term = values["widgetTerm"] as? Int ?? old["term"] as? Int
    let week = values["widgetCurrentWeek"] as? Int ?? old["week"] as? Int
    guard let year, let term, let week else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "组件刷新缺少学年、学期或周次", details: nil))
      return
    }
    guard saveWidgetRefreshSession(sessionId) else {
      result(FlutterError(code: "KEYCHAIN_WRITE_FAILED", message: "无法安全保存组件刷新会话", details: nil))
      return
    }
    defaults.set(["baseUrl": baseUrl, "year": year, "term": term, "week": week], forKey: widgetRefreshConfigDefaultsKey)
    scheduleWidgetRefresh()
    result(true)
  }

  private func scheduleWidgetRefresh() {
    guard #available(iOS 13.0, *) else { return }
    guard UserDefaults.standard.dictionary(forKey: widgetRefreshConfigDefaultsKey) != nil else { return }
    let request = BGAppRefreshTaskRequest(identifier: widgetRefreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      NSLog("widget_refresh_schedule_failed: %@", error.localizedDescription)
    }
  }

  @available(iOS 13.0, *)
  private func handleWidgetRefresh(_ task: BGAppRefreshTask) {
    guard let config = UserDefaults.standard.dictionary(forKey: widgetRefreshConfigDefaultsKey),
          let baseUrl = config["baseUrl"] as? String,
          let year = config["year"] as? Int,
          let term = config["term"] as? Int,
          let week = config["week"] as? Int,
          let sessionId = loadWidgetRefreshSession() else {
      task.setTaskCompleted(success: false)
      return
    }
    guard let url = URL(string: "\(baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/widget-snapshot?year=\(year)&term=\(term)&week=\(week)") else {
      task.setTaskCompleted(success: false)
      return
    }
    let request = NSMutableURLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
    if let etag = UserDefaults.standard.string(forKey: widgetRefreshEtagDefaultsKey) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let dataTask = URLSession.shared.dataTask(with: request as URLRequest) { [weak self] data, response, error in
      defer { self?.scheduleWidgetRefresh() }
      guard error == nil, let response = response as? HTTPURLResponse else {
        task.setTaskCompleted(success: false)
        return
      }
      if response.statusCode == 401 {
        self?.clearWidgetRefreshConfiguration()
        task.setTaskCompleted(success: false)
        return
      }
      if response.statusCode == 304 {
        task.setTaskCompleted(success: true)
        return
      }
      guard response.statusCode == 200, let data else {
        task.setTaskCompleted(success: false)
        return
      }
      if let etag = response.value(forHTTPHeaderField: "ETag"), let self {
        UserDefaults.standard.set(etag, forKey: self.widgetRefreshEtagDefaultsKey)
      }
      task.setTaskCompleted(success: self?.storeWidgetSnapshot(data, currentWeek: week) ?? false)
    }
    task.expirationHandler = { dataTask.cancel() }
    dataTask.resume()
  }

  private func storeWidgetSnapshot(_ data: Data, currentWeek: Int) -> Bool {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modules = payload["modules"] as? [String: Any],
          let defaults = UserDefaults(suiteName: homeWidgetsAppGroup) else { return false }
    let payloadChanged = defaults.data(forKey: "widgetSnapshotPayload") != data
    defaults.set(data, forKey: "widgetSnapshotPayload")
    defaults.set(Int64(Date().timeIntervalSince1970 * 1_000), forKey: "widgetUpdatedAtEpochMillis")
    if let schedule = moduleList(modules, name: "schedule") {
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
    if payloadChanged {
      WidgetCenter.shared.reloadAllTimelines()
    }
    return true
  }

  private func moduleList(_ modules: [String: Any], name: String) -> [[String: Any]]? {
    guard let module = modules[name] as? [String: Any], module["status"] as? String != "error" else { return nil }
    return module["data"] as? [[String: Any]]
  }

  private func moduleObject(_ modules: [String: Any], name: String) -> [String: Any]? {
    guard let module = modules[name] as? [String: Any], module["status"] as? String != "error" else { return nil }
    return module["data"] as? [String: Any]
  }

  private func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  private func storeTodaySchedule(
    _ courses: [[String: Any]],
    currentWeek: Int,
    defaults: UserDefaults
  ) {
    let calendar = Calendar.current
    let now = Date()
    let weekday = ((calendar.component(.weekday, from: now) + 5) % 7) + 1
    let today = courses.compactMap { course -> [String: Any]? in
      guard intValue(course["weekday"]) == weekday,
            let startSection = intValue(course["startSection"]),
            let endSection = intValue(course["endSection"]),
            startSection >= 1, endSection <= widgetSectionTimes.count,
            occursInWeek(course["weeks"] as? String ?? "", currentWeek: currentWeek) else { return nil }
      let startTime = widgetSectionTimes[startSection - 1].0
      let endTime = widgetSectionTimes[endSection - 1].1
      let start = dateToday(startTime, calendar: calendar, now: now)
      let end = dateToday(endTime, calendar: calendar, now: now)
      return [
        "time": startTime,
        "name": course["name"] as? String ?? "课程",
        "info": [course["classroom"] as? String, course["teacher"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
        "ongoing": start <= now && now < end,
        "start": start,
        "end": end,
      ]
    }.sorted { ($0["start"] as? Date ?? now) < ($1["start"] as? Date ?? now) }
    let visibleCourses = today.map { course in
      [
        "time": course["time"] as? String ?? "",
        "name": course["name"] as? String ?? "课程",
        "info": course["info"] as? String ?? "",
        "ongoing": course["ongoing"] as? Bool ?? false,
      ]
    }
    let next = today.first { ($0["end"] as? Date ?? now) > now }
    defaults.set(jsonString(visibleCourses), forKey: "todayCoursesJson")
    defaults.set(today.map { "\($0["time"] as? String ?? "") \($0["name"] as? String ?? "课程")" }, forKey: "todayItems")
    defaults.set(today.isEmpty ? "今日无课" : "今日 \(today.count) 节课", forKey: "todayTitle")
    defaults.set("第\(currentWeek)周 · \(today.count) 节课", forKey: "todayMeta")
    defaults.set(next?["name"] as? String ?? "暂无下一节课", forKey: "nextTitle")
    defaults.set(next?["time"] as? String ?? "", forKey: "nextTime")
    defaults.set(next?["info"] as? String ?? "", forKey: "nextClassroom")
    defaults.set(next == nil ? "none" : ((next?["ongoing"] as? Bool ?? false) ? "ongoing" : "upcoming"), forKey: "nextStatus")
    defaults.set(Int64(((next?["start"] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextStartEpochMillis")
    defaults.set(Int64(((next?["end"] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000), forKey: "nextEndEpochMillis")
  }

  private func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }

  private func occursInWeek(_ spec: String, currentWeek: Int) -> Bool {
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

  private func dateToday(_ time: String, calendar: Calendar, now: Date) -> Date {
    let values = time.split(separator: ":").compactMap { Int($0) }
    return calendar.date(bySettingHour: values[0], minute: values[1], second: 0, of: now) ?? now
  }

  private func widgetKinds(forValueKey key: String) -> Set<String> {
    if key.hasPrefix("next") { return [nextClassHomeScreenWidgetKind, nextClassLockScreenWidgetKind] }
    if key.hasPrefix("today") { return [todayCoursesWidgetKind] }
    if key.hasPrefix("utility") { return [utilitiesWidgetKind] }
    if key.hasPrefix("progress") { return [progressWidgetKind] }
    if key.hasPrefix("exam") { return [examCountdownWidgetKind] }
    if key.hasPrefix("grade") { return [gradesWidgetKind] }
    return []
  }

  private func reloadWidgetTimelines(_ kinds: Set<String>) {
    guard #available(iOS 14.0, *) else { return }
    for kind in kinds {
      WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
  }

  private func saveWidgetRefreshSession(_ sessionId: String) -> Bool {
    let data = Data(sessionId.utf8)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: widgetRefreshKeychainService, kSecAttrAccount as String: widgetRefreshKeychainAccount]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = data
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  private func loadWidgetRefreshSession() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: widgetRefreshKeychainService, kSecAttrAccount as String: widgetRefreshKeychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func clearWidgetRefreshConfiguration() {
    UserDefaults.standard.removeObject(forKey: widgetRefreshConfigDefaultsKey)
    UserDefaults.standard.removeObject(forKey: widgetRefreshEtagDefaultsKey)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: widgetRefreshKeychainService, kSecAttrAccount as String: widgetRefreshKeychainAccount]
    SecItemDelete(query as CFDictionary)
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: widgetRefreshTaskIdentifier)
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.scheme == "cn.gzus.pro", ["widget", "activity"].contains(url.host),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let tab = components.queryItems?.first(where: { $0.name == "tab" })?.value,
          ["schedule", "exams", "grades", "ecard", "business", "notices", "attendance"].contains(tab) else {
      return super.application(app, open: url, options: options)
    }
    UserDefaults.standard.set(tab, forKey: pendingWidgetTabDefaultsKey)
    homeWidgets?.invokeMethod("launch", arguments: ["tab": tab])
    return true
  }

  private func registerLiquidGlass(with engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: liquidGlassChannelName) else {
      fatalError("无法注册液态玻璃 Platform View：Flutter registrar 不可用")
    }
    let channel = FlutterMethodChannel(
      name: liquidGlassChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "APP_DEALLOCATED", message: "应用已释放", details: nil))
        return
      }
      self.handleLiquidGlassMethod(call: call, result: result)
    }
    liquidGlassChannel = channel
    registrar.register(LiquidGlassViewFactory(), withId: liquidGlassChannelName)
    registrar.register(
      NativeLiquidTabBarViewFactory(channel: channel) { [weak self] tabBar in
        self?.nativeLiquidTabBar = tabBar
      },
      withId: "cn.gzus.pro/native-liquid-tab-bar"
    )

    NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.liquidGlassChannel?.invokeMethod(
        "capabilitiesChanged",
        arguments: self?.liquidGlassCapabilities()
      )
    }
  }

  private func handleLiquidGlassMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(liquidGlassCapabilities())
    case "updateNativeTabBarSelected":
      guard let arguments = call.arguments as? [String: Any],
            let selectedIndex = arguments["selectedIndex"] as? NSNumber else {
        result(FlutterError(
          code: "INVALID_ARGUMENT",
          message: "原生底栏状态同步需要 selectedIndex。",
          details: nil
        ))
        return
      }
      guard let nativeLiquidTabBar else {
        result(false)
        return
      }
      nativeLiquidTabBar.setSelectedIndex(selectedIndex.intValue)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func liquidGlassCapabilities() -> [String: Bool] {
    let supportsSystemGlass: Bool
    if #available(iOS 26.0, *) {
      supportsSystemGlass = true
    } else {
      supportsSystemGlass = false
    }
    return [
      "systemGlassSupported": supportsSystemGlass,
      "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
    ]
  }
}

private final class LiquidGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    guard let arguments = args as? [String: Any],
          let material = arguments["material"] as? String,
          let cornerRadiusNumber = arguments["cornerRadius"] as? NSNumber else {
      preconditionFailure("液态玻璃 Platform View 参数无效：需要 material 和 cornerRadius")
    }
    return LiquidGlassPlatformView(
      frame: frame,
      material: material,
      cornerRadius: CGFloat(truncating: cornerRadiusNumber)
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class LiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let rootView: UIView
  private let material: String
  private let cornerRadius: CGFloat

  init(frame: CGRect, material: String, cornerRadius: CGFloat) {
    rootView = UIView(frame: frame)
    self.material = material
    self.cornerRadius = cornerRadius
    super.init()
    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    rootView.isUserInteractionEnabled = false
    renderEffect()
  }

  func view() -> UIView {
    rootView
  }

  private func renderEffect() {
    rootView.subviews.forEach { $0.removeFromSuperview() }
    let effectView: UIVisualEffectView
    if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
      let style: UIGlassEffect.Style
      switch material {
      case "regular":
        style = .regular
      case "clear":
        style = .clear
      default:
        preconditionFailure("液态玻璃材质无效：\(material)")
      }
      let effect = UIGlassEffect(style: style)
      effect.isInteractive = false
      effectView = UIVisualEffectView(effect: effect)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    effectView.frame = rootView.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.backgroundColor = .clear
    effectView.isOpaque = false
    effectView.isUserInteractionEnabled = false
    effectView.layer.cornerRadius = cornerRadius
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    rootView.addSubview(effectView)
  }
}

private final class NativeLiquidTabBarViewFactory: NSObject, FlutterPlatformViewFactory {
  private let channel: FlutterMethodChannel
  private let onViewCreated: (NativeLiquidTabBarView) -> Void

  init(
    channel: FlutterMethodChannel,
    onViewCreated: @escaping (NativeLiquidTabBarView) -> Void
  ) {
    self.channel = channel
    self.onViewCreated = onViewCreated
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    guard let arguments = args as? [String: Any],
          let selectedIndex = arguments["selectedIndex"] as? NSNumber,
          let tintColor = arguments["tintColor"] as? NSNumber,
          let itemArguments = arguments["items"] as? [[String: Any]] else {
      preconditionFailure("原生液态底栏 Platform View 参数无效")
    }
    let items = itemArguments.enumerated().map { index, item in
      guard let title = item["title"] as? String,
            let systemImageName = item["systemImageName"] as? String else {
        preconditionFailure("原生液态底栏项目参数无效：需要 title 和 systemImageName")
      }
      return NativeLiquidTabBarItem(
        index: index,
        title: title,
        systemImageName: systemImageName
      )
    }
    let tabBar = NativeLiquidTabBarView(
      frame: frame,
      items: items,
      selectedIndex: selectedIndex.intValue,
      tintColor: UIColor(argb: tintColor.uint32Value),
      channel: channel
    )
    onViewCreated(tabBar)
    return tabBar
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private struct NativeLiquidTabBarItem {
  let index: Int
  let title: String
  let systemImageName: String
}

private final class NativeLiquidTabBarView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let rootView: UIView
  private let tabBar: UITabBar
  private let channel: FlutterMethodChannel
  private let itemCount: Int

  init(
    frame: CGRect,
    items: [NativeLiquidTabBarItem],
    selectedIndex: Int,
    tintColor: UIColor,
    channel: FlutterMethodChannel
  ) {
    precondition(!items.isEmpty, "原生液态底栏至少需要一个项目")
    precondition(
      items.indices.contains(selectedIndex),
      "原生液态底栏的 selectedIndex 超出项目范围"
    )
    rootView = UIView(frame: frame)
    tabBar = UITabBar()
    self.channel = channel
    itemCount = items.count
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    let tabBarItems = items.map { item in
      UITabBarItem(
        title: item.title,
        image: UIImage(systemName: item.systemImageName),
        tag: item.index
      )
    }
    tabBar.items = tabBarItems
    tabBar.selectedItem = tabBarItems[selectedIndex]
    tabBar.delegate = self
    tabBar.tintColor = tintColor
    let tabBarHeight = tabBar.sizeThatFits(rootView.bounds.size).height
    tabBar.frame = CGRect(
      x: 0,
      y: rootView.bounds.height - tabBarHeight,
      width: rootView.bounds.width,
      height: tabBarHeight
    )
    tabBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
    rootView.addSubview(tabBar)
  }

  func view() -> UIView {
    rootView
  }

  func setSelectedIndex(_ selectedIndex: Int) {
    guard (0 ..< itemCount).contains(selectedIndex) else {
      preconditionFailure("原生液态底栏的 selectedIndex 超出项目范围")
    }
    guard let items = tabBar.items else {
      preconditionFailure("原生液态底栏缺少项目")
    }
    tabBar.selectedItem = items[selectedIndex]
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard (0 ..< itemCount).contains(item.tag) else {
      preconditionFailure("原生液态底栏选择项不属于当前底栏")
    }
    channel.invokeMethod("nativeTabSelected", arguments: item.tag)
  }
}

private extension UIColor {
  convenience init(argb: UInt32) {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255
    let red = CGFloat((argb >> 16) & 0xFF) / 255
    let green = CGFloat((argb >> 8) & 0xFF) / 255
    let blue = CGFloat(argb & 0xFF) / 255
    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }
}

/// iOS 26 当前会在 Flutter 的触摸帧率校正初始化中触发引擎空指针。
/// 该校正仅用于高刷新率下调整触摸回调节奏，不影响 Flutter 渲染或触摸事件分发。
@objc(RunnerFlutterViewController)
final class RunnerFlutterViewController: FlutterViewController {
  @objc(createTouchRateCorrectionVSyncClientIfNeeded)
  func disableTouchRateCorrectionVSyncClient() {}
}
