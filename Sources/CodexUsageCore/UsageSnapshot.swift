import Foundation

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let usedPercent: Int
    public let resetAt: Date

    public init(id: String, label: String, usedPercent: Int, resetAt: Date) {
        self.id = id
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let plan: String
    public let updatedAt: Date
    public let windows: [UsageWindow]
    public let resetCredits: Int
    public let source: String
    public let accountKey: String?

    public init(
        plan: String,
        updatedAt: Date,
        windows: [UsageWindow],
        resetCredits: Int,
        source: String,
        accountKey: String? = nil
    ) {
        self.plan = plan
        self.updatedAt = updatedAt
        self.windows = windows
        self.resetCredits = max(resetCredits, 0)
        self.source = source
        self.accountKey = accountKey
    }

    public static let sample: UsageSnapshot = {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let shortReset = calendar.date(byAdding: .hour, value: 5, to: now) ?? now
        let weeklyReset = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return UsageSnapshot(
            plan: "Plus",
            updatedAt: now,
            windows: [
                UsageWindow(id: "five-hour", label: "5시간 한도", usedPercent: 1, resetAt: shortReset),
                UsageWindow(id: "weekly", label: "주간 한도", usedPercent: 16, resetAt: weeklyReset)
            ],
            resetCredits: 2,
            source: "sample",
            accountKey: nil
        )
    }()
}

public enum UsageSnapshotCodec {
    public static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
