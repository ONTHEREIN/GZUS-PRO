import Flutter
import UIKit
import Bugly

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let buglyChannel = "cn.gzus.pro/bugly"
  private var buglyInitialized = false
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 初始化 Bugly
    if let buglyAppId = Bundle.main.object(forInfoDictionaryKey: "BuglyAppId") as? String {
      let config = BuglyConfig()
      config.channel = Bundle.main.object(forInfoDictionaryKey: "BuglyChannel") as? String ?? "gzus_pro"
      #if DEBUG
      config.debugMode = true
      #endif
      Bugly.start(withAppId: buglyAppId, config: config)
      buglyInitialized = true
    }
    
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    
    // 设置 Bugly method channel
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: buglyChannel, binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleBuglyMethod(call: call, result: result)
      }
    }
  }
  
  private func handleBuglyMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      result(buglyInitialized)
    case "setUserId":
      if let userId = call.arguments as? [String: Any], let id = userId["userId"] as? String {
        Bugly.setUserIdentifier(id)
        result(true)
      } else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "userId is required", details: nil))
      }
    case "setTag":
      if let tagArg = call.arguments as? [String: Any], let tagId = tagArg["tagId"] as? Int {
        Bugly.setTag(tagId)
        result(true)
      } else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "tagId is required", details: nil))
      }
    case "setUserData":
      if let data = call.arguments as? [String: Any], 
         let key = data["key"] as? String, 
         let value = data["value"] as? String {
        Bugly.setUserValue(value, forKey: key)
        result(true)
      } else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "key and value are required", details: nil))
      }
    case "reportException":
      if let exceptionData = call.arguments as? [String: Any],
         let exception = exceptionData["exception"] as? String,
         let stackTrace = exceptionData["stackTrace"] as? String {
        let userInfo = ["stackTrace": stackTrace]
        Bugly.reportException(NSException(name: NSExceptionName(rawValue: "CustomException"), reason: exception, userInfo: userInfo))
        result(true)
      } else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "exception and stackTrace are required", details: nil))
      }
    case "testCrash":
      Bugly.testCrash()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
