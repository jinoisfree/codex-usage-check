import Foundation

public protocol UsageProvider: Sendable {
    func loadSnapshot() async throws -> UsageSnapshot
}

public enum UsageProviderError: LocalizedError, Equatable {
    case missingFile(URL)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .missingFile(let url): return "사용량 캐시 파일이 없습니다: \(url.path)"
        case .invalidData: return "사용량 캐시 형식이 올바르지 않습니다."
        }
    }
}

public struct LocalJSONUsageProvider: UsageProvider {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func loadSnapshot() async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageProviderError.missingFile(url)
        }
        do {
            return try UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: Data(contentsOf: url))
        } catch {
            throw UsageProviderError.invalidData
        }
    }
}

public struct FixtureUsageProvider: UsageProvider {
    public init() {}
    public func loadSnapshot() async throws -> UsageSnapshot { .sample }
}

public enum UsageCache {
    public static let fileName = "usage-snapshot.json"
    public static let applicationBundleIdentifier = "com.jino.codex-usage"
    public static let widgetBundleIdentifier = "com.jino.codex-usage.widget"
    public static let appGroupIdentifier = "group.com.jino.codex-usage"

    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = applicationBundleIdentifier
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    public static func widgetSandboxSnapshotURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationBundleIdentifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func sharedSnapshotURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    public static func write(
        _ snapshot: UsageSnapshot,
        fileManager: FileManager = .default
    ) throws {
        let url = try applicationSupportURL(fileManager: fileManager)
        let data = try UsageSnapshotCodec.encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)

        let widgetURL = widgetSandboxSnapshotURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: widgetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: widgetURL, options: .atomic)
    }
}
