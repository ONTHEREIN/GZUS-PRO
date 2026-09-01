import Flutter
import UIKit
import CoreLocation
import EventKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CLLocationManagerDelegate {
  private let homeWidgetsChannel = "cn.gzus.pro/home_widgets"
  private let homeWidgetsAppGroup = "group.cn.gzus.pro.6772c5tf6c"
  private let nextClassHomeScreenWidgetKind = "OneGzusNextClassHomeScreen"
  private let nextClassLockScreenWidgetKind = "OneGzusNextClassLockScreen"
  private let liquidGlassChannelName = "cn.gzus.pro/liquid-glass"
  private let permissionsChannelName = "cn.gzus.pro/permissions"
  private let locationChannelName = "cn.gzus.pro/location"
  private let pushChannelName = "cn.gzus.pro/push"
  private let calendarChannelName = "cn.gzus.pro/calendar"
  private let remotePushTokenDefaultsKey = "remote_push_token"
  private let notificationOpenDefaultsKey = "notification_open_extras"
  private var liquidGlassChannel: FlutterMethodChannel?
  private weak var nativeLiquidTabBar: NativeLiquidTabBarView?
  private var pendingRemotePushTokenResult: FlutterResult?
  private var locationManager: CLLocationManager?
  private var pendingLocationResult: FlutterResult?
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ShiplyManager.shared().initializeSDK()
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      cacheNotificationOpen(userInfo)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
    var lastError: String?
    for raw in events {
      guard let start = (raw["startMillis"] as? NSNumber)?.doubleValue,
            let end = (raw["endMillis"] as? NSNumber)?.doubleValue else {
        continue
      }
      let event = EKEvent(eventStore: store)
      event.title = raw["title"] as? String ?? "软帮手日程"
      event.startDate = Date(timeIntervalSince1970: start / 1000)
      event.endDate = Date(timeIntervalSince1970: end / 1000)
      event.location = raw["location"] as? String
      event.notes = raw["description"] as? String
      event.calendar = targetCalendar
      do {
        try store.save(event, span: .thisEvent, commit: true)
        added += 1
      } catch {
        lastError = error.localizedDescription
      }
    }
    if added > 0 {
      result(added)
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
      "nextTitle", "nextMeta", "nextDetail", "nextClassroom", "nextTeacher", "nextStatus", "nextTime"
    ]
    for key in stringKeys {
      defaults.set(values[key] as? String ?? "", forKey: key)
    }
    let numberKeys = [
      "nextStartEpochMillis", "nextEndEpochMillis", "widgetUpdatedAtEpochMillis"
    ]
    for key in numberKeys {
      defaults.set((values[key] as? NSNumber)?.int64Value ?? 0, forKey: key)
    }
    WidgetCenter.shared.reloadTimelines(ofKind: nextClassHomeScreenWidgetKind)
    if #available(iOS 16.0, *) {
      WidgetCenter.shared.reloadTimelines(ofKind: nextClassLockScreenWidgetKind)
    }
    result(true)
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
