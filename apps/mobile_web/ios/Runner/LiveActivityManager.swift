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
    private let liveActivityInstallationAccount = "installation-id"
    private weak var channel: FlutterMethodChannel?
    private var observerTasks: [Task<Void, Never>] = []
    private var observedActivityIds: Set<String> = []
    private var pushTokenTasks: [String: Task<Void, Never>] = [:]
    private var activityStateTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        self.channel = channel
        observePushToStartTokens()
        observeActivityUpdates()
        for activity in Activity<GzusLiveActivityAttributes>.activities {
            observeActivity(for: activity)
        }
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
                "installationId": installationIdentifier(),
            ]
            if let token = currentPushToStartToken() {
                capabilities["pushToStartToken"] = token
            }
            result(capabilities)
        case "registerPushToStartToken":
            if let value = currentPushToStartToken() {
                syncToken(token: value, tokenType: "start", activityId: nil, activityType: nil, expiresAt: nil)
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
            syncToken(token: token, tokenType: "start", activityId: nil, activityType: nil, expiresAt: nil)
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
            deepLink: payload.deepLink,
            priority: payload.priority
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
        Task { [weak self] in
            guard let self else { return }
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
                self.observeActivity(for: activity)
                await MainActor.run { result(["activityId": activity.id]) }
            } catch let caughtError {
                await MainActor.run {
                    result(self.error(code: "START_FAILED", message: "启动灵动岛失败: \(caughtError.localizedDescription)"))
                }
            }
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
        Activity<GzusLiveActivityAttributes>.activities.first {
            $0.attributes.activityId == id
        }
    }

    private func observePushToStartTokens() {
        guard #available(iOS 17.2, *) else { return }
        observerTasks.append(Task { [weak self] in
            guard let self else { return }
            for await token in Activity<GzusLiveActivityAttributes>.pushToStartTokenUpdates {
                let value = self.tokenString(token)
                self.syncToken(token: value, tokenType: "start", activityId: nil, activityType: nil, expiresAt: nil)
                self.send(method: "pushToStartToken", arguments: ["token": value])
            }
        })
    }

    private func observeActivityUpdates() {
        observerTasks.append(Task { [weak self] in
            for await activity in Activity<GzusLiveActivityAttributes>.activityUpdates {
                self?.observeActivity(for: activity)
            }
        })
    }

    private func observeActivity(for activity: Activity<GzusLiveActivityAttributes>) {
        let activityId = activity.id
        guard observedActivityIds.insert(activityId).inserted else { return }
        observePushToken(for: activity)
        activityStateTasks[activityId] = Task { [weak self] in
            guard let self else { return }
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self.send(method: "activityEnded", arguments: [
                    "activityId": activity.attributes.activityId,
                ])
                self.unregisterToken(
                    activityId: activity.attributes.activityId,
                    environment: self.currentEnvironment(),
                    deviceId: self.installationIdentifier()
                )
                self.pushTokenTasks.removeValue(forKey: activityId)?.cancel()
                self.activityStateTasks.removeValue(forKey: activityId)
                self.observedActivityIds.remove(activityId)
                break
            }
        }
    }

    private func observePushToken(for activity: Activity<GzusLiveActivityAttributes>) {
        let activityId = activity.id
        guard pushTokenTasks[activityId] == nil else { return }
        let expiresAt = activityEndDate(activity)
        pushTokenTasks[activityId] = Task { [weak self] in
            guard let self else { return }
            for await token in activity.pushTokenUpdates {
                let value = self.tokenString(token)
                self.syncToken(
                    token: value,
                    tokenType: "activity",
                    activityId: activity.attributes.activityId,
                    activityType: activity.attributes.activityType,
                    expiresAt: expiresAt
                )
                self.send(method: "activityToken", arguments: [
                    "activityId": activity.attributes.activityId,
                    "token": value,
                    "activityType": activity.attributes.activityType,
                    "expiresAt": self.iso8601(expiresAt),
                ])
            }
        }
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
        activityType: String?,
        expiresAt: Date?
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
            "deviceId": installationIdentifier(),
        ]
        if let activityId, !activityId.isEmpty { body["activityId"] = activityId }
        if let activityType, !activityType.isEmpty { body["activityType"] = activityType }
        if let expiresAt { body["expiresAt"] = iso8601(expiresAt) }
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
                if status == 401 {
                    var retryArguments: [String: String] = [
                        "token": token,
                        "tokenType": tokenType,
                    ]
                    if let activityId, !activityId.isEmpty {
                        retryArguments["activityId"] = activityId
                    }
                    if let activityType, !activityType.isEmpty {
                        retryArguments["activityType"] = activityType
                    }
                    if let expiresAt {
                        retryArguments["expiresAt"] = self.iso8601(expiresAt)
                    }
                    self.send(method: "tokenSyncRequiresSession", arguments: retryArguments)
                }
                return
            }
            NSLog("live_activity_token_sync_succeeded: token_type=%@ status=%ld", tokenType, response.statusCode)
        }.resume()
    }

    private func unregisterToken(activityId: String, environment: String, deviceId: String) {
        guard let config = UserDefaults(suiteName: appGroupIdentifier)?.dictionary(forKey: liveActivityConfigKey),
              let baseUrl = config["baseUrl"] as? String,
              let sessionId = loadSession(),
              let url = URL(string: "\(baseUrl)/push/ios/live-activity-tokens/activity/unregister") else {
            return
        }
        let body: [String: String] = [
            "activityId": activityId,
            "environment": environment,
            "deviceId": deviceId,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("live_activity_token_unregister_failed: %@", error.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                NSLog("live_activity_token_unregister_failed: status=%ld", status)
                return
            }
            NSLog("live_activity_token_unregister_succeeded: status=%ld", status)
        }.resume()
    }

    private func currentEnvironment() -> String {
        let config = UserDefaults(suiteName: appGroupIdentifier)?.dictionary(forKey: liveActivityConfigKey)
        return config?["environment"] as? String ?? "production"
    }

    private func activityEndDate(_ activity: Activity<GzusLiveActivityAttributes>) -> Date? {
        let endEpochMillis: Int64
        if #available(iOS 16.2, *) {
            endEpochMillis = activity.content.state.endEpochMillis
        } else {
            endEpochMillis = activity.contentState.endEpochMillis
        }
        guard endEpochMillis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(endEpochMillis) / 1000)
    }

    private func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func installationIdentifier() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveActivitySessionService,
            kSecAttrAccount as String: liveActivityInstallationAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.lowercased()
        var saved = query
        saved.removeValue(forKey: kSecReturnData as String)
        saved.removeValue(forKey: kSecMatchLimit as String)
        saved[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(saved as CFDictionary, nil) == errSecSuccess else {
            return value
        }
        return value
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
        let metrics = (values["utilityMetrics"] as? [[String: Any]] ?? []).compactMap { value -> LiveActivityMetric? in
            guard let label = value["label"] as? String,
                  let metricValue = value["value"] as? String else { return nil }
            return LiveActivityMetric(label: label, value: metricValue, isAlert: value["isAlert"] as? Bool ?? false)
        }
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
                ongoing: ongoing,
                courseName: values["courseName"] as? String,
                location: values["location"] as? String,
                seat: values["seat"] as? String,
                score: values["score"] as? String,
                gradeStatus: values["gradeStatus"] as? String,
                gradePassed: values["gradePassed"] as? Bool,
                utilityMetrics: metrics,
                utilityPrimaryLabel: values["utilityPrimaryLabel"] as? String,
                utilityPrimaryValue: values["utilityPrimaryValue"] as? String
            ),
            priority: (values["priority"] as? NSNumber)?.intValue ?? 5,
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
        pushTokenTasks.values.forEach { $0.cancel() }
        activityStateTasks.values.forEach { $0.cancel() }
    }
}

@available(iOS 16.1, *)
private struct ActivityPayload {
    let activityId: String
    let activityType: String
    let targetTab: String
    let deepLink: String
    let contentState: GzusLiveActivityAttributes.ContentState
    let priority: Int
    let staleDate: Date?
    let dismissalDate: Date
    let dismissImmediately: Bool
}
