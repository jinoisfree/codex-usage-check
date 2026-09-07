import CryptoKit
import Foundation

/// Reads the active Codex account and rate-limit buckets through the local
/// `codex app-server` JSONL protocol. It never persists or displays an email
/// address or access token.
public struct AppServerUsageProvider: UsageProvider {
    public let executableURL: URL

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL()
    }

    public func loadSnapshot() async throws -> UsageSnapshot {
        let executableURL = executableURL
        return try await Task.detached(priority: .utility) {
            try Self.readSnapshot(executableURL: executableURL)
        }.value
    }

    private static func defaultExecutableURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            ?? candidates[0]
    }

    private static func readSnapshot(executableURL: URL) throws -> UsageSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let requests = [
            "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"codex_usage_widget\",\"title\":\"Codex Usage Widget\",\"version\":\"0.2.0\"}}}",
            "{\"method\":\"initialized\",\"params\":{}}",
            "{\"method\":\"account/read\",\"id\":1,\"params\":{\"refreshToken\":false}}",
            "{\"method\":\"account/rateLimits/read\",\"id\":2}"
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))
        // app-server performs account/rate-limit reads asynchronously. Keep
        // stdin open briefly so the responses are flushed before shutdown.
        Thread.sleep(forTimeInterval: 5.0)
        input.fileHandleForWriting.closeFile()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageProviderError.invalidData
        }
        return try parseSnapshot(from: data)
    }

    private static func parseSnapshot(from data: Data) throws -> UsageSnapshot {
        var account: [String: Any]?
        var limits: [String: Any]?

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            switch json["id"] as? Int {
            case 1: account = (json["result"] as? [String: Any])?["account"] as? [String: Any]
            case 2: limits = json["result"] as? [String: Any]
            default: continue
            }
        }

        guard let account, let limits else { throw UsageProviderError.invalidData }
        let plan = account["planType"] as? String ?? "unknown"
        let type = account["type"] as? String ?? "unknown"
        let identityMaterial = (account["email"] as? String) ?? "\(type):\(plan)"
        let accountKey = SHA256.hash(data: Data(identityMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)

        let buckets = (limits["rateLimitsByLimitId"] as? [String: Any]) ?? [:]
        guard let codex = buckets["codex"] as? [String: Any] else {
            throw UsageProviderError.invalidData
        }

        var windows: [UsageWindow] = []
        if let primary = codex["primary"] as? [String: Any],
           let window = makeWindow(from: primary, fallbackID: "codex-primary") {
            windows.append(window)
        }
        if let secondary = codex["secondary"] as? [String: Any],
           let window = makeWindow(from: secondary, fallbackID: "codex-secondary") {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw UsageProviderError.invalidData }

        let resetCredits = ((limits["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? NSNumber)?.intValue ?? 0
        return UsageSnapshot(
            plan: plan,
            updatedAt: .now,
            windows: windows.sorted { $0.resetAt < $1.resetAt },
            resetCredits: resetCredits,
            source: "app-server",
            accountKey: String(accountKey)
        )
    }

    private static func makeWindow(from raw: [String: Any], fallbackID: String) -> UsageWindow? {
        guard let used = (raw["usedPercent"] as? NSNumber)?.intValue,
              let duration = (raw["windowDurationMins"] as? NSNumber)?.intValue,
              let reset = (raw["resetsAt"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let label: String
        switch duration {
        case 300: label = "5시간 한도"
        case 10080: label = "주간 한도"
        default: label = "\(duration)분 한도"
        }
        return UsageWindow(
            id: fallbackID,
            label: label,
            usedPercent: used,
            resetAt: Date(timeIntervalSince1970: reset)
        )
    }
}
