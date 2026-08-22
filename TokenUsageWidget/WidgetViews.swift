import SwiftUI

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BalanceEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    // MARK: - 小号：单个服务商

    private var smallView: some View {
        Group {
            if let summary = entry.summaries.first {
                VStack(alignment: .leading, spacing: 6) {
                    providerHeader(summary)
                    Spacer(minLength: 0)
                    Text(Formatting.cny(summary.latestTotal))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(summary.provider.accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    SparklineView(values: summary.history, lineColor: summary.provider.accentColor)
                        .frame(height: 28)
                    Text(updatedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                placeholder
            }
        }
        .padding()
    }

    // MARK: - 中号：两个服务商并排

    private var mediumView: some View {
        Group {
            if entry.summaries.isEmpty {
                placeholder
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(entry.summaries.enumerated()), id: \.element.id) { index, summary in
                        providerColumn(summary)
                        if index < entry.summaries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func providerColumn(_ summary: ProviderSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            providerHeader(summary)
            Text(Formatting.cny(summary.latestTotal))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(summary.provider.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            SparklineView(values: summary.history, lineColor: summary.provider.accentColor)
                .frame(height: 24)
            HStack {
                Text("今日 \(Formatting.cny(summary.todayConsumption, decimals: 3))")
                Spacer()
                Text(updatedText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 公共

    private var updatedText: String {
        guard let updatedAt = entry.updatedAt else { return "无数据" }
        return updatedAt.formatted(date: .omitted, time: .shortened) + " 更新"
    }

    private func providerHeader(_ summary: ProviderSummary) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(summary.provider.accentColor)
                .frame(width: 7, height: 7)
            Text(summary.provider.displayName)
                .font(.caption.weight(.semibold))
            if summary.keyCount > 1 {
                Text("×\(summary.keyCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("打开 TokenUsage 配置 API Key")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
