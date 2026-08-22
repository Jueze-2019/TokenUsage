import SwiftUI
import WidgetKit

/// 小组件展示用的服务商汇总（多 Key 已聚合）。
struct ProviderSummary: Identifiable, Sendable {
    var id: AIProvider { provider }
    let provider: AIProvider
    let keyCount: Int
    let latestTotal: Double
    let currency: String
    let history: [Double]        // 合计余额趋势
    let todayConsumption: Double
}

/// 小组件时间线条目。
struct BalanceEntry: TimelineEntry {
    let date: Date
    let summaries: [ProviderSummary]
    let updatedAt: Date?

    /// 占位/预览用的示例数据
    static var sample: BalanceEntry {
        let now = Date()
        let history = (0..<20).map { i in
            92 - Double(19 - i) * 0.4 + sin(Double(19 - i) / 2.5) * 1.5
        }
        let summary = ProviderSummary(
            provider: .deepseek,
            keyCount: 2,
            latestTotal: history.last ?? 0,
            currency: "CNY",
            history: history,
            todayConsumption: 1.28
        )
        return BalanceEntry(date: now, summaries: [summary], updatedAt: now)
    }
}

struct BalanceTimelineProvider: TimelineProvider {
    typealias Entry = BalanceEntry

    func placeholder(in context: Context) -> BalanceEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let entry = loadEntry()
        // 15 分钟后请求新时间线；主 App 每次刷新也会主动 reloadAllTimelines
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> BalanceEntry {
        guard let cache = SharedStore.read() else {
            return BalanceEntry(date: Date(), summaries: [], updatedAt: nil)
        }
        var summaries: [ProviderSummary] = []
        for provider in AIProvider.allCases {
            let providerKeys = cache.keys.filter { $0.provider == provider }
            let datas = providerKeys
                .compactMap { cache.dataByKey[$0.id.uuidString] }
                .filter { $0.latest != nil }
            guard !datas.isEmpty else { continue }
            summaries.append(
                ProviderSummary(
                    provider: provider,
                    keyCount: providerKeys.count,
                    latestTotal: datas.compactMap { $0.latest?.totalBalance }.reduce(0, +),
                    currency: datas.compactMap { $0.latest?.currency }.first ?? "CNY",
                    history: datas.aggregatedBalanceHistory().suffix(30).map(\.total),
                    todayConsumption: datas
                        .map { $0.consumption(since: Calendar.current.startOfDay(for: Date())) }
                        .reduce(0, +)
                )
            )
        }
        return BalanceEntry(date: Date(), summaries: summaries, updatedAt: cache.updatedAt)
    }
}

struct BalanceWidget: Widget {
    let kind = "BalanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceTimelineProvider()) { entry in
            BalanceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Token 用量")
        .description("实时展示 DeepSeek / Kimi 的账户余额与用量趋势。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
