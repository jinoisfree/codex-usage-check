import Foundation
import CodexUsageCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let clamped = UsageWindow(id: "test", label: "테스트", usedPercent: 140, resetAt: .now)
check(clamped.usedPercent == 100, "사용률은 100을 넘지 않아야 합니다")
check(clamped.remainingPercent == 0, "남은 비율은 0보다 작아지지 않아야 합니다")

let snapshot = try await FixtureUsageProvider().loadSnapshot()
check(snapshot.source == "sample", "fixture source가 sample이어야 합니다")
check(snapshot.windows.map(\.id) == ["five-hour", "weekly"], "두 사용량 창이 있어야 합니다")

let encoded = try UsageSnapshotCodec.encoder.encode(snapshot)
let decoded = try UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: encoded)
check(decoded.plan == snapshot.plan, "JSON 왕복 후 플랜이 같아야 합니다")
check(decoded.windows.map(\.usedPercent) == snapshot.windows.map(\.usedPercent), "JSON 왕복 후 사용률이 같아야 합니다")
check(decoded.resetCredits == snapshot.resetCredits, "JSON 왕복 후 초기화 크레딧이 같아야 합니다")

let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-smoke.json")
try encoded.write(to: cacheURL, options: .atomic)
defer { try? FileManager.default.removeItem(at: cacheURL) }
let cached = try await LocalJSONUsageProvider(url: cacheURL).loadSnapshot()
check(cached.source == snapshot.source, "로컬 JSON 공급자가 source를 보존해야 합니다")

if ProcessInfo.processInfo.environment["CODEX_USAGE_LIVE_PROBE"] == "1" {
    let live = try await AppServerUsageProvider().loadSnapshot()
    check(live.source == "app-server", "App Server 공급자 source가 app-server여야 합니다")
    check(!live.windows.isEmpty, "App Server가 최소 한 개의 사용량 창을 반환해야 합니다")
    print("Codex App Server live probe: PASS (plan=\(live.plan), windows=\(live.windows.count))")
}

print("CodexUsageCore smoke: PASS")
