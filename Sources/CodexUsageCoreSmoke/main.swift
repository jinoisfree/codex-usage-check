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

let accountAData = Data(#"{"tokens":{"account_id":"account-a"}}"#.utf8)
let accountBData = Data(#"{"tokens":{"account_id":"account-b"}}"#.utf8)
let accountAKey = try AccountIdentity.fingerprint(fromAuthData: accountAData)
let accountBKey = try AccountIdentity.fingerprint(fromAuthData: accountBData)
check(accountAKey.count == 12, "계정 fingerprint는 12자리여야 합니다")
check(accountAKey != accountBKey, "서로 다른 계정의 fingerprint가 달라야 합니다")
check(accountAKey == AccountIdentity.fingerprint("account-a"), "동일 계정 fingerprint는 결정적이어야 합니다")

let switching = UsageSnapshot.accountSwitching(accountKey: accountBKey)
check(switching.windows.isEmpty, "계정 전환 중에는 이전 사용량을 포함하지 않아야 합니다")
check(switching.accountKey == accountBKey, "계정 전환 상태는 새 계정 fingerprint를 가져야 합니다")
check(switching.statusMessage != nil, "계정 전환 상태는 안내 문구를 제공해야 합니다")
let switchingRoundTrip = try UsageSnapshotCodec.iso8601.decode(
    UsageSnapshot.self,
    from: UsageSnapshotCodec.encoder.encode(switching)
)
check(switchingRoundTrip.source == switching.source, "계정 전환 source가 JSON 왕복 후 보존되어야 합니다")
check(switchingRoundTrip.accountKey == switching.accountKey, "계정 fingerprint가 JSON 왕복 후 보존되어야 합니다")
check(switchingRoundTrip.statusMessage == switching.statusMessage, "계정 전환 문구가 JSON 왕복 후 보존되어야 합니다")
check(switchingRoundTrip.windows.isEmpty, "계정 전환 상태가 JSON 왕복 후에도 사용량을 포함하지 않아야 합니다")

if ProcessInfo.processInfo.environment["CODEX_USAGE_LIVE_PROBE"] == "1" {
    let live = try await AppServerUsageProvider().loadSnapshot()
    let activeAccountKey = try AccountIdentity.activeFingerprint()
    check(live.source == "app-server", "App Server 공급자 source가 app-server여야 합니다")
    check(!live.windows.isEmpty, "App Server가 최소 한 개의 사용량 창을 반환해야 합니다")
    check(live.accountKey == activeAccountKey, "실시간 사용량이 현재 인증 계정과 일치해야 합니다")
    print("Codex App Server live probe: PASS (plan=\(live.plan), windows=\(live.windows.count))")
}

print("CodexUsageCore smoke: PASS")

let expired = UsageSnapshot(plan: "Claude", updatedAt: .now, windows: [
    UsageWindow(id: "old", label: "5시간 한도", usedPercent: 30,
                resetAt: Date().addingTimeInterval(-1))
], resetCredits: 0, source: "claude-statusline")
check(expired.displaySnapshot().windows.isEmpty, "초기화 지난 값은 재사용하지 않습니다")
check(expired.displaySnapshot().statusMessage != nil, "재확인 상태가 표시됩니다")
let missing = UsageSnapshot.unavailable("미연동", service: .claude)
check(missing.badgeText == "—", "미연동은 가짜 0%나 100%가 아닙니다")
let ordered = UsageSnapshot(plan: "Plus", updatedAt: .now, windows: [
    UsageWindow(id: "weekly", label: "주간 한도", usedPercent: 30, resetAt: .distantFuture),
    UsageWindow(id: "five", label: "5시간 한도", usedPercent: 12, resetAt: .distantFuture)
], resetCredits: 0, source: "app-server")
check(ordered.representativeWindow?.id == "five", "메뉴바는 초기화 순서 대신 5시간 창을 우선합니다")
print("Multi-service smoke: PASS")
let historical = UsageSnapshot(plan: "Desktop", updatedAt: .now.addingTimeInterval(-61),
    windows: ordered.windows, resetCredits: 0, source: "claude-desktop-history")
check(historical.badgeText == "—", "오래된 Claude 기록을 현재 잔여량처럼 표시하지 않습니다")
let weeklyOnly = UsageSnapshot(plan: "Plus", updatedAt: .now,
    windows: [ordered.windows[0]], resetCredits: 0, source: "app-server")
check(weeklyOnly.badgeText == "W70%", "5시간 한도가 없으면 주간 남은 양을 표시합니다")
