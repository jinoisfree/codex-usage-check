import SwiftUI
import WidgetKit
import Foundation
import Combine
import CoreText
import Darwin
import CodexUsageCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var snapshot = UsageSnapshot.unavailable("계정 확인 중", service: .codex)
    @Published var claudeSnapshot = UsageSnapshot.unavailable("Claude 연결 확인 중", service: .claude)
    @Published var menuMode = UserDefaults.standard.string(forKey: "usageMenuMode") ?? "both" {
        didSet { UserDefaults.standard.set(menuMode, forKey: "usageMenuMode") }
    }
    @Published var showingUsed = false
    @Published var connectionMessage: String?
    @Published var claudeDirectEnabled = readClaudeDirectConsent()
    @Published var changingClaudeDirect = false
    private var claudePollingTask: Task<Void, Never>?
    private var claudeRefreshGeneration = 0

    private static func readClaudeDirectConsent() -> Bool {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: base.appendingPathComponent("com.jino.codex-usage/claude-direct-consent.json")),
              let consent = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return consent["enabled"] as? Bool == true
    }

    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<UsageSnapshot?, Never>?
    private var retryTask: Task<Void, Never>?
    private var observedAccountKey: String?
    private var refreshGeneration = 0

    func startPolling() {
        guard pollingTask == nil else { return }
        accountDidChange()
        claudePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshClaude()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.refresh()
            }
        }
    }

    func accountDidChange() {
        let nextAccountKey = try? AccountIdentity.activeFingerprint()
        guard nextAccountKey != observedAccountKey || snapshot.source == "codex-unavailable" else { return }

        observedAccountKey = nextAccountKey
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        retryTask?.cancel()
        retryTask = nil
        apply(.accountSwitching(accountKey: nextAccountKey))

        if nextAccountKey != nil {
            Task { await refresh() }
        }
    }

    func refresh() async {
        let activeAccountKey = try? AccountIdentity.activeFingerprint()
        if activeAccountKey != observedAccountKey {
            accountDidChange()
            return
        }
        guard let expectedAccountKey = activeAccountKey else { return }

        if let refreshTask {
            _ = await refreshTask.value
            return
        }

        let generation = refreshGeneration
        let task = Task {
            try? await AppServerUsageProvider().loadSnapshot()
        }
        refreshTask = task
        let live = await task.value

        guard generation == refreshGeneration,
              observedAccountKey == expectedAccountKey,
              (try? AccountIdentity.activeFingerprint()) == expectedAccountKey else {
            return
        }
        refreshTask = nil

        if let live, live.accountKey == expectedAccountKey {
            apply(live)
            return
        }

        apply(snapshot.displaySnapshot())
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            await self?.refresh()
        }
    }

    private func apply(_ next: UsageSnapshot) {
        let changed = !next.hasSameWidgetContent(as: snapshot)
        snapshot = next
        guard changed else { return }
        do {
            try UsageCache.write(next)
        } catch {
            // A WidgetKit cache failure must not freeze the menu bar.
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refreshClaude() async {
        guard let script = Bundle.main.url(forResource: "claude_bridge", withExtension: "py") else {
            claudeSnapshot = .unavailable("Claude 수집기 설치 필요", service: .claude)
            return
        }
        let generation = claudeRefreshGeneration
        let next = await ClaudeUsageProvider(scriptURL: script).loadSnapshot()
        guard generation == claudeRefreshGeneration else { return }
        let changed = !next.hasSameWidgetContent(as: claudeSnapshot)
        claudeSnapshot = next
        if changed {
            try? ServiceUsageCache.writeClaude(next)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func connectClaude() async {
        let result = await runClaudeCommand("connect")
        connectionMessage = result.message
        await refreshClaude()
    }

    func setClaudeDirect(_ enabled: Bool) async {
        guard !changingClaudeDirect else { return }
        changingClaudeDirect = true
        claudeRefreshGeneration += 1
        let result = await runClaudeCommand(enabled ? "enable-desktop-direct" : "disable-desktop-direct")
        claudeDirectEnabled = Self.readClaudeDirectConsent()
        connectionMessage = result.succeeded ? nil : result.message
        await refreshClaude()
        changingClaudeDirect = false
    }

    private func runClaudeCommand(_ mode: String) async -> (message: String, succeeded: Bool) {
        guard let script = Bundle.main.url(forResource: "claude_bridge", withExtension: "py") else {
            return ("Claude 수집기 설치 필요", false)
        }
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, mode]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (String(decoding: data, as: UTF8.self), process.terminationStatus == 0)
            } catch { return ("연결 실행 실패. Python 3 설치를 확인하세요.", false) }
        }.value
    }
}

@MainActor
final class AccountChangeMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounceTask: Task<Void, Never>?

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard source == nil else { return }
        let directory = AccountIdentity.authURL().deletingLastPathComponent()
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.debounceTask?.cancel()
                self?.debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }
}

@MainActor
final class CodexUsageAppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageViewModel()
    private var statusItem: NSStatusItem?
    private var snapshotCancellable: AnyCancellable?
    private var singletonLockDescriptor: CInt = -1
    private let popover = NSPopover()
    private let accountMonitor = AccountChangeMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingletonLock() else {
            NSApplication.shared.terminate(nil)
            return
        }
        ProcessInfo.processInfo.disableAutomaticTermination("Codex Usage background refresh")
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.jino.codex-usage.remaining"
        statusItem.isVisible = true
        self.statusItem = statusItem
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            updateStatusItem(for: model.snapshot)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        snapshotCancellable = Publishers.CombineLatest3(
            model.$snapshot, model.$claudeSnapshot, model.$menuMode
        ).sink { [weak self] snapshot, claude, mode in
            Task { @MainActor in
                self?.updateStatusItem(for: snapshot, claude: claude, mode: mode)
            }
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 332, height: 474)
        popover.contentViewController = NSHostingController(
            rootView: UnifiedUsagePopover(model: model)
                .frame(width: 316)
                .padding(8)
                .task { await self.model.refresh() }
        )
        model.startPolling()
        accountMonitor.start { [weak model = model] in model?.accountDidChange() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if singletonLockDescriptor >= 0 {
            close(singletonLockDescriptor)
            singletonLockDescriptor = -1
        }
    }

    private func acquireSingletonLock() -> Bool {
        let path = "/private/tmp/com.jino.codex-usage.\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        singletonLockDescriptor = descriptor
        return true
    }

    private func updateStatusItem(for snapshot: UsageSnapshot,
                                  claude: UsageSnapshot? = nil, mode: String = "both") {
        guard let button = statusItem?.button else { return }
        let codex = snapshot.displaySnapshot()
        let claude = (claude ?? model.claudeSnapshot).displaySnapshot()
        let selected = mode == "claude" ? claude : codex
        let singleText = selected.badgeText
        let text = mode == "both" ? "CX \(codex.badgeText) · CL \(claude.badgeText)" : singleText
        button.image = usageBadgeImage(text: text, combined: mode == "both")
        button.toolTip = [(UsageService.codex, codex), (.claude, claude)].map { service, value in
            let detail = value.statusMessage ?? value.windows.map { window in
                let reset = window.resetAt.map { "\(remainingTime(until: $0)) 후 초기화" } ?? "초기화 시각 미제공"
                return "\(window.label): \(window.remainingPercent)% 남음 · \(reset)"
            }.joined(separator: "\n")
            let query = value.detail.map { "\n" + $0 } ?? ""
            return "\(service.title)\n\(detail)\n마지막 확인: \(value.updatedAt.formatted())\(query)"
        }.joined(separator: "\n\n") + "\n덜 남은 한도 표시 · * 10분 이상 지난 관측값 · W 주간 한도"
        button.setAccessibilityLabel(button.toolTip)
    }

    private func usageBadgeImage(text: String, combined: Bool = false) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(label)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let size = NSSize(width: max(27, ceil(lineWidth) + (combined ? 6 : 4)), height: 14)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSColor.black.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()

            if let context = NSGraphicsContext.current?.cgContext {
                context.textPosition = CGPoint(
                    x: (bounds.width - lineWidth) / 2,
                    y: bounds.midY - (ascent - descent) / 2
                )
                CTLineDraw(line, context)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AI 남은 사용량 \(text)"
        return image
    }

    private func remainingTime(until resetAt: Date) -> String {
        let interval = max(resetAt.timeIntervalSinceNow, 0)
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(CodexUsageAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private struct UnifiedUsagePopover: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 남은 사용량").font(.headline)
            Picker("메뉴바", selection: $model.menuMode) {
                Text("모두").tag("both")
                Text("Codex").tag("codex")
                Text("Claude").tag("claude")
            }.pickerStyle(.segmented)
            serviceCard("Codex", snapshot: model.snapshot.displaySnapshot(), color: .green)
            Divider()
            serviceCard("Claude", snapshot: model.claudeSnapshot.displaySnapshot(), color: .orange)
            Toggle("Claude 직접 조회", isOn: Binding(
                get: { model.claudeDirectEnabled },
                set: { enabled in Task { await model.setClaudeDirect(enabled) } }
            ))
                .font(.caption)
                .disabled(model.changingClaudeDirect)
            HStack {
                Button("Claude 열기") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
                }
                Spacer()
                Button("새로고침") {
                    Task { await model.refresh() }
                    Task { await model.refreshClaude() }
                }
            }
            Text(model.claudeSnapshot.detail ?? model.connectionMessage ?? (model.claudeSnapshot.source == "claude-desktop-direct"
                ? "Claude 서버 직접 조회 · 2분 간격 · 덜 남은 한도 표시"
                : "Claude 데스크톱의 마지막 관측값입니다. 초기화 시각은 미제공입니다."))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(8)
    }

    private func serviceCard(_ title: String, snapshot: UsageSnapshot, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(snapshot.plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let message = snapshot.statusMessage {
                Text(message).foregroundStyle(.secondary).font(.caption)
                    .frame(minHeight: 62)
            } else {
                ForEach(snapshot.windows) { window in
                    VStack(spacing: 3) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text("\(window.remainingPercent)% 남음").bold()
                        }.font(.caption)
                        ProgressView(value: Double(window.remainingPercent), total: 100).tint(color)
                        HStack {
                            Spacer()
                            if let resetAt = window.resetAt {
                                Text("초기화까지")
                                Text(resetAt, style: .relative)
                            } else {
                                Text("초기화 시각 미제공")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("마지막 확인")
                Text(snapshot.updatedAt, style: .time)
                if Date().timeIntervalSince(snapshot.updatedAt) > 600 { Text("· 오래된 값") }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct UsagePopover: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.green.gradient, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 사용량").font(.subheadline.weight(.semibold))
                    Text("\(model.snapshot.plan) · \(sourceLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(.green).frame(width: 7, height: 7)
            }

            if let statusMessage = model.snapshot.statusMessage {
                Text(statusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                HStack(spacing: 10) {
                    ForEach(model.snapshot.windows) { window in
                        UsageMeter(window: window, showingUsed: model.showingUsed)
                            .onTapGesture { model.showingUsed.toggle() }
                    }
                }
            }

            HStack {
                Label(statusLabel, systemImage: statusIcon)
                    .foregroundStyle(model.snapshot.statusMessage == nil ? .green : .orange)
                Spacer()
                Text("초기화 크레딧 \(model.snapshot.resetCredits)회")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("카드를 클릭해 사용/남음 전환")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.snapshot.updatedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sourceLabel: String {
        switch model.snapshot.source {
        case "app-server": return "활성 계정"
        case "sample": return "샘플 데이터"
        case "account-switching": return "계정 확인 중"
        default: return "로컬 캐시"
        }
    }

    private var statusLabel: String {
        model.snapshot.statusMessage == nil ? "정상" : "갱신 중"
    }

    private var statusIcon: String {
        model.snapshot.statusMessage == nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"
    }
}

private struct UsageMeter: View {
    let window: UsageWindow
    let showingUsed: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            CircularUsageIndicator(percent: window.remainingPercent)
                .frame(width: 44, height: 44)
                .offset(x: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(showingUsed ? "\(window.usedPercent)% 사용" : "\(window.remainingPercent)% 남음")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text(window.resetAt.map { $0.formatted() } ?? "초기화 시각 미제공")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: -3)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
        .padding(6)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CircularUsageIndicator: View {
    let percent: Int

    private var progress: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.green.opacity(0.28), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    .green,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.65)
                .lineLimit(1)
        }
    }
}
