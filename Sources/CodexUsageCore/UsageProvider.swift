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

    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "com.jino.codex-usage"
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
}
