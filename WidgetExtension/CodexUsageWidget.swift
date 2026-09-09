import SwiftUI
import WidgetKit
import Foundation
import CodexUsageCore

struct CodexUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct CodexUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexUsageEntry {
        CodexUsageEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageEntry) -> Void) {
        completion(CodexUsageEntry(date: .now, snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageEntry>) -> Void) {
        let entry = CodexUsageEntry(date: .now, snapshot: loadSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> UsageSnapshot {
        if let url = try? UsageCache.applicationSupportURL(),
           let data = try? Data(contentsOf: url),
           let snapshot = try? UsageSnapshotCodec.iso8601.decode(UsageSnapshot.self, from: data) {
            return snapshot
        }

        return .sample
    }
}

struct CodexUsageWidgetView: View {
    let entry: CodexUsageEntry
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(.green.gradient, in: RoundedRectangle(cornerRadius: 6))
                Text("Codex")
                    .font(.headline.weight(.bold))
                Spacer()
                Text(entry.snapshot.plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
                    Text(window.resetAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Label("남은 양", systemImage: "chart.bar.fill")
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
        StaticConfiguration(kind: kind, provider: CodexUsageProvider()) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 사용량")
        .description("5시간·주간 Codex 남은 양을 표시합니다.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageWidget() }
}
