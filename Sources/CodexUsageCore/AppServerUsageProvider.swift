import Foundation
import CoreFoundation
import Darwin

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
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            ?? candidates[0]
    }

    private static func readSnapshot(executableURL: URL) throws -> UsageSnapshot {
        let expectedAccountKey = try AccountIdentity.activeFingerprint()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        func send(_ message: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
        }
        try send(#"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_usage_widget","title":"Codex Usage Widget","version":"0.4.2"}}}"#)
        var buffer = Data(), responses = Data()
        var initialized = false
        var received = Set<Int>()
        var totalBytes = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageProviderError.invalidData }
            totalBytes += count
            guard totalBytes <= 1_048_576 else { throw UsageProviderError.invalidData }
            buffer.append(contentsOf: bytes.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                if id == 0 && !initialized {
                    guard object["error"] == nil else { throw UsageProviderError.invalidData }
                    try send(#"{"method":"initialized","params":{}}"#)
                    try send(#"{"method":"account/read","id":1,"params":{"refreshToken":false}}"#)
                    try send(#"{"method":"account/rateLimits/read","id":2}"#)
                    initialized = true
                } else if initialized && (id == 1 || id == 2) {
                    guard object["error"] == nil else { throw UsageProviderError.invalidData }
                    responses.append(line)
                    responses.append(10)
                    received.insert(id)
                    if received.count == 2 {
                        let snapshot = try parseSnapshot(from: responses, accountKey: expectedAccountKey)
                        guard try AccountIdentity.activeFingerprint() == expectedAccountKey else {
                            throw UsageProviderError.accountChanged
                        }
                        return snapshot
                    }
                }
            }
        }
        throw UsageProviderError.invalidData
    }

    public static func parseSnapshot(from data: Data, accountKey: String) throws -> UsageSnapshot {
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

        if let returnedAccountID = limits["accountId"] as? String,
           AccountIdentity.fingerprint(returnedAccountID) != accountKey {
            throw UsageProviderError.accountChanged
        }

        let buckets = (limits["rateLimitsByLimitId"] as? [String: Any]) ?? [:]
        let namedCodex = buckets["codex"] as? [String: Any]
        let identifiedCodex = buckets.values
            .compactMap { $0 as? [String: Any] }
            .first { ($0["limitId"] as? String) == "codex" }
        guard let codex = namedCodex ?? identifiedCodex ?? (limits["rateLimits"] as? [String: Any]) else {
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
            windows: windows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) },
            resetCredits: resetCredits,
            source: "app-server",
            accountKey: accountKey
        )
    }

    private static func makeWindow(from raw: [String: Any], fallbackID: String) -> UsageWindow? {
        guard let number = raw["usedPercent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue),
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
            usedPercent: Int(ceil(number.doubleValue)),
            resetAt: Date(timeIntervalSince1970: reset)
        )
    }
}
