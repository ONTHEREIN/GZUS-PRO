import ActivityKit

@available(iOS 16.1, *)
struct LiveActivityMetric: Codable, Hashable {
    let label: String
    let value: String
    let isAlert: Bool
}

@available(iOS 16.1, *)
struct GzusLiveActivityAttributes: ActivityAttributes {
    let activityId: String
    let activityType: String
    let targetTab: String
    let deepLink: String
    let priority: Int?

    struct ContentState: Codable, Hashable {
        let title: String
        let body: String
        let shortText: String
        let startEpochMillis: Int64
        let endEpochMillis: Int64
        let progress: Double?
        let ongoing: Bool
        let courseName: String?
        let location: String?
        let seat: String?
        let score: String?
        let gradeStatus: String?
        let gradePassed: Bool?
        let utilityMetrics: [LiveActivityMetric]
        let utilityPrimaryLabel: String?
        let utilityPrimaryValue: String?

        private enum CodingKeys: String, CodingKey {
            case title, body, shortText, startEpochMillis, endEpochMillis, progress, ongoing
            case courseName, location, seat, score, gradeStatus, gradePassed
            case utilityMetrics, utilityPrimaryLabel, utilityPrimaryValue
        }

        init(
            title: String,
            body: String,
            shortText: String,
            startEpochMillis: Int64,
            endEpochMillis: Int64,
            progress: Double?,
            ongoing: Bool,
            courseName: String? = nil,
            location: String? = nil,
            seat: String? = nil,
            score: String? = nil,
            gradeStatus: String? = nil,
            gradePassed: Bool? = nil,
            utilityMetrics: [LiveActivityMetric] = [],
            utilityPrimaryLabel: String? = nil,
            utilityPrimaryValue: String? = nil
        ) {
            self.title = title
            self.body = body
            self.shortText = shortText
            self.startEpochMillis = startEpochMillis
            self.endEpochMillis = endEpochMillis
            self.progress = progress
            self.ongoing = ongoing
            self.courseName = courseName
            self.location = location
            self.seat = seat
            self.score = score
            self.gradeStatus = gradeStatus
            self.gradePassed = gradePassed
            self.utilityMetrics = utilityMetrics
            self.utilityPrimaryLabel = utilityPrimaryLabel
            self.utilityPrimaryValue = utilityPrimaryValue
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            body = try values.decode(String.self, forKey: .body)
            shortText = try values.decode(String.self, forKey: .shortText)
            startEpochMillis = try values.decode(Int64.self, forKey: .startEpochMillis)
            endEpochMillis = try values.decode(Int64.self, forKey: .endEpochMillis)
            progress = try values.decodeIfPresent(Double.self, forKey: .progress)
            ongoing = try values.decode(Bool.self, forKey: .ongoing)
            courseName = try values.decodeIfPresent(String.self, forKey: .courseName)
            location = try values.decodeIfPresent(String.self, forKey: .location)
            seat = try values.decodeIfPresent(String.self, forKey: .seat)
            score = try values.decodeIfPresent(String.self, forKey: .score)
            gradeStatus = try values.decodeIfPresent(String.self, forKey: .gradeStatus)
            gradePassed = try values.decodeIfPresent(Bool.self, forKey: .gradePassed)
            utilityMetrics = try values.decodeIfPresent([LiveActivityMetric].self, forKey: .utilityMetrics) ?? []
            utilityPrimaryLabel = try values.decodeIfPresent(String.self, forKey: .utilityPrimaryLabel)
            utilityPrimaryValue = try values.decodeIfPresent(String.self, forKey: .utilityPrimaryValue)
        }
    }
}
