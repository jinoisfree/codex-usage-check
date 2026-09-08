import SwiftUI
import AppKit
import CoreGraphics
import CodexUsageCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var snapshot = UsageSnapshot.sample
    @Published var showingUsed = false

    private var refreshTask: Task<Void, Never>?

    func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        if let live = try? await AppServerUsageProvider().loadSnapshot() {
            snapshot = live
            return
        }
        guard let url = try? UsageCache.applicationSupportURL(),
              let cached = try? await LocalJSONUsageProvider(url: url).loadSnapshot() else {
            return
        }
        snapshot = cached
    }
}

@MainActor
final class DesktopWidgetWindowController: NSObject {
    private let panel: NSPanel
    private let model: UsageViewModel
    private var dragStartOrigin: NSPoint?
    private static let savedOriginKey = "CodexUsageWidget.origin"

    init(model: UsageViewModel) {
        self.model = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 292, height: 200)
        let defaultOrigin = NSPoint(x: screen.maxX - size.width - 36, y: screen.maxY - size.height - 36)
        let origin = Self.loadSavedOrigin() ?? defaultOrigin
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.contentView = NSHostingView(
            rootView: UsagePopover(
                model: model,
                onDragChanged: { [weak self] translation in
                    self?.move(by: translation)
                },
                onDragEnded: { [weak self] in
                    self?.finishDragging()
                }
            )
                .frame(width: 276, height: 184)
                .padding(8)
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
    }

    private static func loadSavedOrigin() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: savedOriginKey) else { return nil }
        return NSPointFromString(raw)
    }

    private func move(by translation: CGSize) {
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
        }
        guard let start = dragStartOrigin else { return }
        panel.setFrameOrigin(NSPoint(
            x: start.x + translation.width,
            y: start.y - translation.height
        ))
    }

    private func finishDragging() {
        guard dragStartOrigin != nil else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.savedOriginKey)
        dragStartOrigin = nil
    }

    func show() {
        panel.orderFrontRegardless()
        model.startPolling()
    }
}

@MainActor
final class CodexUsageAppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageViewModel()
    private var desktopController: DesktopWidgetWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktopController = DesktopWidgetWindowController(model: model)
        desktopController?.show()
    }
}

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(CodexUsageAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopover(model: appDelegate.model)
                .frame(width: 276)
                .padding(8)
                .task { await appDelegate.model.refresh() }
        } label: {
            Label(menuBarLabel, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        guard let window = appDelegate.model.snapshot.windows.first else { return "Codex" }
        return "Codex \(appDelegate.model.showingUsed ? window.usedPercent : window.remainingPercent)%"
    }
}

private struct UsagePopover: View {
    @ObservedObject var model: UsageViewModel
    var onDragChanged: ((CGSize) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil

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

            HStack(spacing: 10) {
                ForEach(model.snapshot.windows) { window in
                    UsageMeter(window: window, showingUsed: model.showingUsed)
                        .onTapGesture { model.showingUsed.toggle() }
                }
            }

            HStack {
                Label("정상", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    onDragChanged?(value.translation)
                }
                .onEnded { _ in
                    onDragEnded?()
                }
        )
    }

    private var sourceLabel: String {
        switch model.snapshot.source {
        case "app-server": return "활성 계정"
        case "sample": return "샘플 데이터"
        default: return "로컬 캐시"
        }
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
