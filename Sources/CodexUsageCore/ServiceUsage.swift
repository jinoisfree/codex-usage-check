import Foundation

public enum UsageService: String, CaseIterable, Sendable {
    case codex, claude
    public var title: String { self == .codex ? "Codex" : "Claude" }
}

public extension UsageSnapshot {
    static func unavailable(_ message: String, service: UsageService) -> UsageSnapshot {
        UsageSnapshot(plan: service.title, updatedAt: .now, windows: [], resetCredits: 0,
                      source: service.rawValue + "-unavailable", statusMessage: message)
    }

    /// Expired observations are unknown, never an inferred 100% remaining.
    func displaySnapshot(now: Date = .now) -> UsageSnapshot {
        guard statusMessage == nil else { return self }
        let active = windows.filter { $0.resetAt.map { $0 > now } ?? true }
        if source == "claude-desktop-direct", now.timeIntervalSince(updatedAt) > 300 {
            return UsageSnapshot(plan: plan, updatedAt: updatedAt, windows: [],
                                 resetCredits: resetCredits, source: source, accountKey: accountKey,
                                 statusMessage: "Claude 서버 재조회 필요")
        }
        if source == "claude-desktop-history", now.timeIntervalSince(updatedAt) > 1800 {
            return UsageSnapshot(plan: plan, updatedAt: updatedAt, windows: [],
                                 resetCredits: resetCredits, source: source, accountKey: accountKey,
                                 statusMessage: "Claude 사용량 재확인 필요 (30분 경과)")
        }
        return UsageSnapshot(plan: plan, updatedAt: updatedAt, windows: active,
                             resetCredits: resetCredits, source: source, accountKey: accountKey,
                             statusMessage: active.isEmpty ? "초기화 후 재확인 대기" : nil)
    }

    var representativeWindow: UsageWindow? {
        windows.first { $0.label.contains("5시간") }
            ?? windows.first { $0.label.contains("주간") }
    }

    var badgeText: String {
        guard statusMessage == nil, let window = representativeWindow else { return "—" }
        // A historical desktop sample is not a live remaining quota.
        if source == "claude-desktop-history", Date().timeIntervalSince(updatedAt) > 60 {
            return "—"
        }
        let prefix = window.label.contains("주간") ? "W" : ""
        let stale = Date().timeIntervalSince(updatedAt) > 600 ? "*" : ""
        return "\(prefix)\(window.remainingPercent)%\(stale)"
    }
}

public enum ServiceUsageCache {
    public static func url(_ service: UsageService) throws -> URL {
        let original = try UsageCache.applicationSupportURL()
        return service == .codex ? original :
            original.deletingLastPathComponent().appendingPathComponent("claude-usage-snapshot.json")
    }

    public static func load(_ service: UsageService) -> UsageSnapshot {
        guard let url = try? url(service), let data = try? Data(contentsOf: url),
              let snapshot = try? UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: data)
        else { return .unavailable("연결 후 갱신 대기", service: service) }
        return snapshot.displaySnapshot()
    }

    public static func writeClaude(_ snapshot: UsageSnapshot) throws {
        let data = try UsageSnapshotCodec.encoder.encode(snapshot)
        try data.write(to: url(.claude), options: .atomic)
        let mirror = UsageCache.widgetSandboxSnapshotURL().deletingLastPathComponent()
            .appendingPathComponent("claude-usage-snapshot.json")
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: mirror, options: .atomic)
    }
}

public struct ClaudeUsageProvider: Sendable {
    public let scriptURL: URL
    public init(scriptURL: URL) { self.scriptURL = scriptURL }

    public func loadSnapshot() async -> UsageSnapshot {
        let scriptURL = scriptURL
        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [scriptURL.path, "read"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                guard process.terminationStatus == 0 else { throw UsageProviderError.invalidData }
                return try UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: data)
                    .displaySnapshot()
            } catch {
                return .unavailable("Claude 연결 확인 실패", service: .claude)
            }
        }.value
    }
}
