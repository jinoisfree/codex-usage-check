import SwiftUI
import WidgetKit
import Foundation
import CodexUsageCore

struct CodexUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    var service: UsageService = .codex
}

struct CodexUsageProvider: TimelineProvider {
    var service: UsageService = .codex
    func placeholder(in context: Context) -> CodexUsageEntry {
        CodexUsageEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageEntry) -> Void) {
        completion(CodexUsageEntry(date: .now, snapshot: loadSnapshot(), service: service))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageEntry>) -> Void) {
        let entry = CodexUsageEntry(date: .now, snapshot: loadSnapshot(), service: service)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> UsageSnapshot {
        ServiceUsageCache.load(service)
    }
}

struct CodexUsageWidgetView: View {
    let entry: CodexUsageEntry
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.service.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                Text(entry.snapshot.plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let statusMessage = entry.snapshot.statusMessage {
                Text(statusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(Array(entry.snapshot.windows.prefix(2))) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(shortLabel(for: window))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(window.remainingPercent)% 남음")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(remainingAmountColor)
                                .lineLimit(1)
                        }
                        UsageProgressBar(remainingPercent: window.remainingPercent)
                        if let resetAt = window.resetAt {
                            Text(resetAt, style: .relative)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("초기화 시각 미제공")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Label(Date().timeIntervalSince(entry.snapshot.updatedAt) > 600 ? "이전 관측값" : "남은 양",
                      systemImage: "chart.bar.fill")
                Spacer()
                Text(entry.snapshot.updatedAt, style: .time)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) {
            if widgetRenderingMode == .fullColor {
                Color(red: 0.02, green: 0.22, blue: 0.35)
                    .opacity(0.78)
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
            }
        }
    }

    private var remainingAmountColor: Color {
        widgetRenderingMode == .fullColor ? .green : .white
    }

    private func shortLabel(for window: UsageWindow) -> String {
        window.label.replacingOccurrences(of: " 한도", with: "")
    }
}

private struct UsageProgressBar: View {
    let remainingPercent: Int
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var progress: CGFloat {
        CGFloat(min(max(remainingPercent, 0), 100)) / 100
    }

    private var fillColor: Color {
        widgetRenderingMode == .fullColor ? .green : .white
    }

    private var trackColor: Color {
        widgetRenderingMode == .fullColor ? .green.opacity(0.28) : .white.opacity(0.24)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)
                Capsule(style: .continuous)
                    .fill(fillColor)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("남은 사용량")
        .accessibilityValue("\(remainingPercent)%")
    }
}

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedUsageProvider()) { entry in
            CompactCombinedUsageView(entry: entry)
        }
        .configurationDisplayName("Codex · Claude 사용량")
        .description("5시간·주간 중 덜 남은 한도를 표시합니다. 같으면 5시간입니다.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageWidget()
        ClaudeUsageWidget()
        CombinedUsageWidget()
    }
}

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexUsageProvider(service: .claude)) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude 사용량")
        .description("Claude Code에서 마지막 확인한 남은 양입니다.")
        .supportedFamilies([.systemSmall])
    }
}

struct CombinedUsageEntry: TimelineEntry {
    let date: Date
    let codex: UsageSnapshot
    let claude: UsageSnapshot
}

struct CompactCombinedUsageView: View {
    let entry: CombinedUsageEntry
    var body: some View {
        VStack(spacing: 5) {
            serviceRow("Codex", snapshot: entry.codex)
            Divider()
            serviceRow("Claude", snapshot: entry.claude)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerBackground(for: .widget) {
            Color(red: 0.02, green: 0.22, blue: 0.35).opacity(0.78)
        }
    }

    private func serviceRow(_ title: String, snapshot: UsageSnapshot) -> some View {
        let windows = snapshot.statusMessage == nil ? ["5시간", "주간"].compactMap { label in
            snapshot.windows.first { $0.label.contains(label) }
        } : []
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .bold))
            if windows.isEmpty {
                Text("최신값 확인 필요").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(windows) { window in
                        quotaCell(window)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func quotaCell(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label.replacingOccurrences(of: " 한도", with: ""))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            UsageProgressBar(remainingPercent: window.remainingPercent)
            if let resetAt = window.resetAt {
                Text(resetAt, style: .relative)
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("초기화까지 남은 시간")
            } else {
                Text("시간 미제공").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CombinedUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CombinedUsageEntry {
        CombinedUsageEntry(date: .now, codex: .sample, claude: .sample)
    }
    func getSnapshot(in context: Context, completion: @escaping (CombinedUsageEntry) -> Void) {
        completion(CombinedUsageEntry(date: .now, codex: ServiceUsageCache.load(.codex),
                                      claude: ServiceUsageCache.load(.claude)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CombinedUsageEntry>) -> Void) {
        getSnapshot(in: context) { entry in
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
        }
    }
}

struct CombinedUsageWidget: Widget {
    let kind = "CombinedUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedUsageProvider()) { entry in
            HStack(spacing: 14) {
                CodexUsageWidgetView(entry: CodexUsageEntry(date: entry.date, snapshot: entry.codex))
                Divider()
                CodexUsageWidgetView(entry: CodexUsageEntry(date: entry.date,
                                                          snapshot: entry.claude, service: .claude))
            }
            .containerBackground(for: .widget) {
                Color(red: 0.02, green: 0.22, blue: 0.35).opacity(0.78)
            }
        }
        .configurationDisplayName("Codex + Claude 사용량")
        .description("두 서비스의 남은 양과 마지막 확인 시각입니다.")
        .supportedFamilies([.systemMedium])
    }
}
