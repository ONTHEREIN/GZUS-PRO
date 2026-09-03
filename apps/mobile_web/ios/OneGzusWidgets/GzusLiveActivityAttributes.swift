import ActivityKit

@available(iOS 16.1, *)
struct GzusLiveActivityAttributes: ActivityAttributes {
    let activityId: String
    let activityType: String
    let targetTab: String
    let deepLink: String

    struct ContentState: Codable, Hashable {
        let title: String
        let body: String
        let shortText: String
        let startEpochMillis: Int64
        let endEpochMillis: Int64
        let progress: Double?
        let ongoing: Bool
    }
}
