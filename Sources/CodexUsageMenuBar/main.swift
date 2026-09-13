import SwiftUI
import WidgetKit
import Foundation
import Darwin
import CodexUsageCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var snapshot = UsageSnapshot.sample
    @Published var showingUsed = false

    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<UsageSnapshot?, Never>?
    private var retryTask: Task<Void, Never>?
    private var observedAccountKey: String?
    private var refreshGeneration = 0

    func startPolling() {
        guard pollingTask == nil else { return }
        accountDidChange()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.refresh()
            }
        }
    }

    func accountDidChange() {
        let nextAccountKey = try? AccountIdentity.activeFingerprint()
        guard nextAccountKey != observedAccountKey || snapshot.source == "sample" else { return }

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
        let widgetURL = UsageCache.widgetSandboxSnapshotURL()
        do {
            try UsageCache.write(next)
            let data = try Data(contentsOf: widgetURL)
            _ = try UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: data)
        } catch {
            return
        }
        snapshot = next
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
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
    private let popover = NSPopover()
    private let accountMonitor = AccountChangeMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Codex Usage background refresh")
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "Codex 사용량"
            )
            button.title = "Codex"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 292, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopover(model: model)
                .frame(width: 276)
                .padding(8)
                .task { await self.model.refresh() }
        )
        model.startPolling()
        accountMonitor.start { [weak model = model] in model?.accountDidChange() }
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
                Text(window.resetAt, style: .relative)
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
