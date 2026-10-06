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
check(decoded.detail == nil, "detail 없는 기존 캐시와 호환되어야 합니다")

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
check(ordered.representativeWindow?.id == "weekly", "메뉴바는 덜 남은 한도를 표시합니다")
check(ordered.badgeText == "W70%", "주간 대표 한도에는 W 접두를 붙입니다")
let tied = UsageSnapshot(plan: "Plus", updatedAt: .now, windows: [
    ordered.windows[0],
    UsageWindow(id: "five", label: "5시간 한도", usedPercent: 30, resetAt: .distantFuture)
], resetCredits: 0, source: "app-server")
check(tied.representativeWindow?.id == "five", "동률이면 5시간 한도를 선택합니다")
check(tied.badgeText == "70%", "5시간 대표 한도에는 W 접두가 없습니다")
let shortFirst = UsageSnapshot(plan: "Plus", updatedAt: .now, windows: [
    ordered.windows[0],
    UsageWindow(id: "five", label: "5시간 한도", usedPercent: 80, resetAt: .distantFuture)
], resetCredits: 0, source: "app-server")
check(shortFirst.representativeWindow?.id == "five", "5시간 잔여량이 적으면 5시간을 선택합니다")
let historical = UsageSnapshot(plan: "Desktop", updatedAt: .now.addingTimeInterval(-61),
    windows: ordered.windows, resetCredits: 0, source: "claude-desktop-history")
check(historical.badgeText == "W70%", "61초 지난 앱 기록은 표시합니다")
let staleHistory = UsageSnapshot(plan: "Desktop", updatedAt: .now.addingTimeInterval(-601),
    windows: ordered.windows, resetCredits: 0, source: "claude-desktop-history")
check(staleHistory.badgeText == "W70%*", "10분 지난 관측값에는 *를 붙입니다")
let oldHistory = UsageSnapshot(plan: "Desktop", updatedAt: .now.addingTimeInterval(-1801),
    windows: ordered.windows, resetCredits: 0, source: "claude-desktop-history")
check(oldHistory.badgeText == "—", "1801초 지난 앱 기록은 숨깁니다")
check(oldHistory.displaySnapshot().windows.isEmpty, "오래된 앱 기록은 위젯에서도 숨깁니다")
let weeklyOnly = UsageSnapshot(plan: "Plus", updatedAt: .now,
    windows: [ordered.windows[0]], resetCredits: 0, source: "app-server")
check(weeklyOnly.badgeText == "W70%", "5시간 한도가 없으면 주간 남은 양을 표시합니다")
for source in ["claude-desktop-direct", "app-server"] {
    let detail = "마지막 조회 14:02 실패: 요청 제한 · 이전 값 표시"
    let retained = UsageSnapshot(plan: "Usage", updatedAt: .now.addingTimeInterval(-601),
        windows: ordered.windows, resetCredits: 2, source: source, accountKey: accountAKey,
        detail: detail)
    check(retained.displaySnapshot().windows.count == 2, "직접 조회와 Codex는 10분 지난 값을 유지합니다")
    check(retained.displaySnapshot().detail == detail, "표시용 스냅샷은 detail을 보존합니다")
    let roundTrip = try UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self,
        from: UsageSnapshotCodec.encoder.encode(retained))
    check(roundTrip.detail == detail, "detail은 JSON 왕복 후 보존됩니다")
    let changedDetail = UsageSnapshot(plan: retained.plan, updatedAt: retained.updatedAt,
        windows: retained.windows, resetCredits: retained.resetCredits, source: source,
        accountKey: accountAKey, detail: "마지막 조회 14:04 성공")
    check(retained != changedDetail, "조회 상태가 바뀌면 팝오버를 갱신합니다")
    check(retained.hasSameWidgetContent(as: changedDetail), "detail만 바뀌면 위젯을 갱신하지 않습니다")
    let old = UsageSnapshot(plan: retained.plan, updatedAt: .now.addingTimeInterval(-3601),
        windows: retained.windows, resetCredits: 2, source: source, detail: detail)
    check(old.displaySnapshot().windows.isEmpty, "3601초 지난 서버 값은 숨깁니다")
    check(old.displaySnapshot().statusMessage?.contains("재조회") == true, "서버 재조회 안내를 제공합니다")
    check(old.displaySnapshot().detail == detail, "만료된 스냅샷도 detail을 보존합니다")
    check(!retained.hasSameWidgetContent(as: old), "관측 시각 변경은 위젯 갱신 대상입니다")
}
print("Multi-service smoke: PASS")

func codexResponse(used: Any, accountID: String = "account-a", namedBucket: Bool = true) throws -> Data {
    let bucket: [String: Any] = [
        "primary": ["usedPercent": used, "windowDurationMins": 300, "resetsAt": 1_900_000_000],
        "secondary": ["usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1_900_086_400]
    ]
    var limits: [String: Any] = ["accountId": accountID, "rateLimitResetCredits": ["availableCount": 2]]
    if namedBucket { limits["rateLimitsByLimitId"] = ["codex": bucket] }
    else { limits["rateLimits"] = bucket }
    let account: [String: Any] = ["id": 1, "result": ["account": ["planType": "plus"]]]
    var data = try JSONSerialization.data(withJSONObject: account)
    data.append(10)
    data.append(try JSONSerialization.data(withJSONObject: ["id": 2, "result": limits]))
    data.append(10)
    return data
}
let parsed = try AppServerUsageProvider.parseSnapshot(from: codexResponse(used: 23.1), accountKey: accountAKey)
check(parsed.windows.first?.usedPercent == 24, "Codex 소수 사용률은 올림합니다")
check(parsed.plan == "plus" && parsed.resetCredits == 2, "Codex 플랜과 초기화 크레딧을 보존합니다")
for invalid: Any in [true, -1, 100.1, "13", NSNull()] {
    let parsed = try AppServerUsageProvider.parseSnapshot(from: codexResponse(used: invalid), accountKey: accountAKey)
    check(parsed.windows.count == 1 && parsed.windows[0].id == "codex-secondary", "잘못된 사용률은 해당 창만 버립니다")
}
for number in ["NaN", "Infinity", "-Infinity"] {
    let text = String(decoding: try codexResponse(used: "invalid-number"), as: UTF8.self)
        .replacingOccurrences(of: "\"invalid-number\"", with: number)
    do {
        let parsed = try AppServerUsageProvider.parseSnapshot(from: Data(text.utf8), accountKey: accountAKey)
        check(!parsed.windows.contains { $0.id == "codex-primary" }, "비유한 사용률을 거부합니다")
    } catch UsageProviderError.invalidData { /* Invalid JSON numbers are also rejected. */ }
}
let legacyLimits = try AppServerUsageProvider.parseSnapshot(from: codexResponse(used: 100, namedBucket: false), accountKey: accountAKey)
check(legacyLimits.windows.first?.remainingPercent == 0, "기존 rateLimits 형식과 100%를 지원합니다")
do {
    _ = try AppServerUsageProvider.parseSnapshot(from: codexResponse(used: 0, accountID: "account-b"), accountKey: accountAKey)
    check(false, "다른 계정의 응답은 거부해야 합니다")
} catch UsageProviderError.accountChanged {}
print("Codex response parsing smoke: PASS")
