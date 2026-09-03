import ActivityKit
import Flutter
import Foundation
import Security

@available(iOS 16.1, *)
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let channelName = "cn.gzus.pro/live_activities"
    private let appGroupIdentifier = "group.cn.gzus.pro.6772c5tf6c"
    private let liveActivityConfigKey = "live_activity_configuration"
    private let liveActivitySessionService = "cn.gzus.pro.live-activity"
    private let liveActivitySessionAccount = "session-id"
    private weak var channel: FlutterMethodChannel?
    private var observerTasks: [Task<Void, Never>] = []

    private init() {}

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        self.channel = channel
        observePushToStartTokens()
        observeActivityUpdates()
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            configure(arguments: call.arguments, result: result)
        case "clearConfiguration":
            clearConfiguration(result: result)
        case "getCapabilities":
            let authorization = ActivityAuthorizationInfo()
            var capabilities: [String: Any] = [
                "available": true,
                "enabled": authorization.areActivitiesEnabled,
            ]
            if let token = currentPushToStartToken() {
                capabilities["pushToStartToken"] = token
            }
            result(capabilities)
        case "registerPushToStartToken":
            if let value = currentPushToStartToken() {
                syncToken(token: value, tokenType: "start", activityId: nil, activityType: nil)
                result(value)
            } else {
                result(nil)
            }
        case "start":
            start(arguments: call.arguments, result: result)
        case "update":
            update(arguments: call.arguments, result: result)
        case "end":
            end(arguments: call.arguments, result: result)
        case "endAll":
            endAll(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func configure(arguments: Any?, result: @escaping FlutterResult) {
        guard let values = arguments as? [String: Any],
              let baseUrl = values["baseUrl"] as? String,
              !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sessionId = values["sessionId"] as? String,
              !sessionId.isEmpty,
              let environment = values["environment"] as? String,
              environment == "sandbox" || environment == "production" else {
            result(error(code: "INVALID_ARGUMENT", message: "灵动岛后台同步配置不完整"))
            return
        }
        guard saveSession(sessionId) else {
            result(error(code: "KEYCHAIN_WRITE_FAILED", message: "无法保存灵动岛后台同步会话"))
            return
        }
        UserDefaults(suiteName: appGroupIdentifier)?.set(
            [
                "baseUrl": baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                "environment": environment,
            ],
            forKey: liveActivityConfigKey
        )
        if let token = currentPushToStartToken() {
            syncToken(token: token, tokenType: "start", activityId: nil, activityType: nil)
        }
        result(true)
    }

    private func clearConfiguration(result: @escaping FlutterResult) {
        UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: liveActivityConfigKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveActivitySessionService,
            kSecAttrAccount as String: liveActivitySessionAccount,
        ]
        SecItemDelete(query as CFDictionary)
        result(true)
    }

    private func start(arguments: Any?, result: @escaping FlutterResult) {
        guard let payload = payload(arguments) else {
            result(error(code: "INVALID_ARGUMENT", message: "灵动岛启动参数无效"))
            return
        }
        let attributes = GzusLiveActivityAttributes(
            activityId: payload.activityId,
            activityType: payload.activityType,
            targetTab: payload.targetTab,
            deepLink: payload.deepLink
        )
        if let existing = activeActivity(id: payload.activityId) {
            Task {
                if #available(iOS 16.2, *) {
                    await existing.update(ActivityContent(state: payload.contentState, staleDate: payload.staleDate))
                } else {
                    await existing.update(using: payload.contentState)
                }
                await MainActor.run { result(["activityId": existing.id, "updated": true]) }
            }
            return
        }
        do {
            let activity: Activity<GzusLiveActivityAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: payload.contentState, staleDate: payload.staleDate),
                    pushType: .token
                )
            } else {
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: payload.contentState,
                    pushType: .token
                )
            }
            observePushToken(for: activity)
            result(["activityId": activity.id])
        } catch let caughtError {
            result(error(code: "START_FAILED", message: "启动灵动岛失败: \(caughtError.localizedDescription)"))
        }
    }

    private func update(arguments: Any?, result: @escaping FlutterResult) {
        guard let payload = payload(arguments) else {
            result(error(code: "INVALID_ARGUMENT", message: "灵动岛更新参数无效"))
            return
        }
        Task {
            guard let activity = activeActivity(id: payload.activityId) else {
                await MainActor.run {
                    result(self.error(code: "ACTIVITY_NOT_FOUND", message: "找不到要更新的灵动岛活动: \(payload.activityId)"))
                }
                return
            }
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: payload.contentState, staleDate: payload.staleDate))
            } else {
                await activity.update(using: payload.contentState)
            }
            await MainActor.run { result(true) }
        }
    }

    private func end(arguments: Any?, result: @escaping FlutterResult) {
        guard let payload = payload(arguments) else {
            result(error(code: "INVALID_ARGUMENT", message: "灵动岛结束参数无效"))
            return
        }
        Task {
            guard let activity = activeActivity(id: payload.activityId) else {
                await MainActor.run { result(true) }
                return
            }
            let dismissalPolicy: ActivityUIDismissalPolicy = payload.dismissImmediately
                ? .immediate
                : .after(payload.dismissalDate)
            if #available(iOS 16.2, *) {
                await activity.end(
                    ActivityContent(state: payload.contentState, staleDate: payload.staleDate),
                    dismissalPolicy: dismissalPolicy
                )
            } else {
                await activity.end(using: payload.contentState, dismissalPolicy: dismissalPolicy)
            }
            await MainActor.run { result(true) }
        }
    }

    private func endAll(result: @escaping FlutterResult) {
        Task {
            for activity in Activity<GzusLiveActivityAttributes>.activities {
                if #available(iOS 16.2, *) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                } else {
                    await activity.end(using: activity.contentState, dismissalPolicy: .immediate)
                }
            }
            await MainActor.run { result(true) }
        }
    }

    private func activeActivity(id: String) -> Activity<GzusLiveActivityAttributes>? {
        Activity<GzusLiveActivityAttributes>.activities.first { $0.id == id }
    }

    private func observePushToStartTokens() {
        guard #available(iOS 17.2, *) else { return }
        observerTasks.append(Task { [weak self] in
            guard let self else { return }
            for await token in Activity<GzusLiveActivityAttributes>.pushToStartTokenUpdates {
                let value = self.tokenString(token)
                self.syncToken(token: value, tokenType: "start", activityId: nil, activityType: nil)
                self.send(method: "pushToStartToken", arguments: ["token": value])
            }
        })
    }

    private func observeActivityUpdates() {
        observerTasks.append(Task { [weak self] in
            for await activity in Activity<GzusLiveActivityAttributes>.activityUpdates {
                self?.observePushToken(for: activity)
            }
        })
    }

    private func observePushToken(for activity: Activity<GzusLiveActivityAttributes>) {
        observerTasks.append(Task { [weak self] in
            guard let self else { return }
            for await token in activity.pushTokenUpdates {
                let value = self.tokenString(token)
                self.syncToken(
                    token: value,
                    tokenType: "activity",
                    activityId: activity.id,
                    activityType: activity.attributes.activityType
                )
                self.send(method: "activityToken", arguments: [
                    "activityId": activity.id,
                    "token": value,
                    "activityType": activity.attributes.activityType,
                ])
            }
        })
    }

    private func currentPushToStartToken() -> String? {
        guard #available(iOS 17.2, *) else { return nil }
        return Activity<GzusLiveActivityAttributes>.pushToStartToken.map(tokenString)
    }

    private func send(method: String, arguments: [String: String]) {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod(method, arguments: arguments)
        }
    }

    private func syncToken(
        token: String,
        tokenType: String,
        activityId: String?,
        activityType: String?
    ) {
        guard let config = UserDefaults(suiteName: appGroupIdentifier)?.dictionary(forKey: liveActivityConfigKey),
              let baseUrl = config["baseUrl"] as? String,
              let environment = config["environment"] as? String,
              environment == "sandbox" || environment == "production",
              let sessionId = loadSession(),
              let url = URL(string: "\(baseUrl)/push/ios/live-activity-tokens") else {
            NSLog("live_activity_token_sync_failed: invalid_configuration")
            return
        }
        var body: [String: Any] = [
            "tokenType": tokenType,
            "token": token,
            "environment": environment,
        ]
        if let activityId, !activityId.isEmpty { body["activityId"] = activityId }
        if let activityType, !activityType.isEmpty { body["activityType"] = activityType }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("live_activity_token_sync_failed: %@", error.localizedDescription)
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("live_activity_token_sync_failed: status=%ld", status)
                return
            }
        }.resume()
    }

    private func saveSession(_ sessionId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveActivitySessionService,
            kSecAttrAccount as String: liveActivitySessionAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(sessionId.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func loadSession() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveActivitySessionService,
            kSecAttrAccount as String: liveActivitySessionAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func payload(_ arguments: Any?) -> ActivityPayload? {
        guard let values = arguments as? [String: Any],
              let activityId = values["activityId"] as? String,
              let activityType = values["activityType"] as? String,
              let title = values["title"] as? String,
              let body = values["body"] as? String else {
            return nil
        }
        let end = int64(values["endEpochMillis"])
        let start = int64(values["startEpochMillis"])
        let targetTab = values["targetTab"] as? String ?? "home"
        let deepLink = values["deepLink"] as? String ?? "cn.gzus.pro://dashboard"
        let shortText = values["shortText"] as? String ?? "软帮手"
        let progress = double(values["progress"])
        let ongoing = values["ongoing"] as? Bool ?? true
        let staleDate = end > 0 ? Date(timeIntervalSince1970: TimeInterval(end) / 1000) : nil
        return ActivityPayload(
            activityId: activityId,
            activityType: activityType,
            targetTab: targetTab,
            deepLink: deepLink,
            contentState: .init(
                title: title,
                body: body,
                shortText: shortText,
                startEpochMillis: start,
                endEpochMillis: end,
                progress: progress,
                ongoing: ongoing
            ),
            staleDate: staleDate,
            dismissalDate: Date(timeIntervalSinceNow: 30 * 60),
            dismissImmediately: values["dismissImmediately"] as? Bool ?? false
        )
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func tokenString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func error(code: String, message: String) -> FlutterError {
        FlutterError(code: code, message: message, details: nil)
    }

    deinit {
        observerTasks.forEach { $0.cancel() }
    }
}

@available(iOS 16.1, *)
private struct ActivityPayload {
    let activityId: String
    let activityType: String
    let targetTab: String
    let deepLink: String
    let contentState: GzusLiveActivityAttributes.ContentState
    let staleDate: Date?
    let dismissalDate: Date
    let dismissImmediately: Bool
}
