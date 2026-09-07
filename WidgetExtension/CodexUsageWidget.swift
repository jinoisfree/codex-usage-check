import SwiftUI
import WidgetKit
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
        completion(CodexUsageEntry(date: .now, snapshot: .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageEntry>) -> Void) {
        let entry = CodexUsageEntry(date: .now, snapshot: .sample)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct CodexUsageWidgetView: View {
    let entry: CodexUsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline.weight(.bold))
                Spacer()
                Text(entry.snapshot.plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.windows) { window in
                HStack(spacing: 8) {
                    ProgressView(value: Double(window.remainingPercent), total: 100)
                        .tint(.green)
                    Text("\(window.remainingPercent)%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                Text(window.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("초기화 크레딧 \(entry.snapshot.resetCredits)회")
                Spacer()
                Text(entry.date, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexUsageProvider()) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 사용량")
        .description("5시간·주간 Codex 사용량과 초기화 시각을 표시합니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageWidget() }
}
