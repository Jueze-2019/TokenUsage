import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// 单个服务商的分区，整体信息架构对齐 DeepSeek 平台「用量信息」页：
/// （多账户时）账户筛选 → 合并余额卡 + 各账户同款余额卡（时间段消耗 / 时间段 Tokens / 累计消费 / 剩余余额）
/// → 各 Key 行 → Key 筛选 + 统计卡（含 token 类型拆分明细）+ 消费金额堆叠图
/// （模型 / API Key 双维度切换）+ 每个模型独立的 Tokens 柱状图（按 输入·命中 / 输入·未命中 / 输出
/// 类型堆叠）与请求次数面积图。
/// 导入数据覆盖导入截止日（含）之前；其后的消耗用余额快照差额实时推算，
/// 合并进统计卡与消费金额图（模型维度按各 Key 最近一天的模型消费占比分摊进对应模型系列）。
/// 有官网登录态的 DeepSeek 账户会定时轻量同步今天/昨天的逐小时数据，
/// 今天/昨天维度的模型归属以官网精确值为准，估算只补足两次同步之间的几分钟。
/// 所有图表支持 hover 显示当天明细数值。
struct ProviderCardView: View {
    let provider: AIProvider
    let range: UsageRange
    @EnvironmentObject private var store: BalanceStore
    /// API Key 多选（JSON 编码的 Set<String>；空串 = 默认全部，空集 = 全不勾放空）
    @AppStorage private var keySelectionRaw: String
    /// 账户多选（JSON 编码的 Set<String>，账户 UUID 串；空串 = 默认全部合并，空集 = 全不勾放空）
    @AppStorage private var accountSelectionRaw: String
    /// 卡片显示模式："detailed"（详细）/ "simple"（简洁：只看所选时间段消耗与剩余）
    @AppStorage private var cardMode: String
    @AppStorage("costChartByKey") private var costChartByKey = false
    // 看板模块显隐（设置页可配）
    @AppStorage("module.balanceCard") private var showBalanceCard = true
    @AppStorage("module.accountCards") private var showAccountCards = true
    @AppStorage("module.keyRows") private var showKeyRows = true
    @AppStorage("module.statCards") private var showStatCards = true
    @AppStorage("module.costChart") private var showCostChart = true
    @AppStorage("module.modelCharts") private var showModelCharts = true
    @AppStorage("module.liveEstimate") private var showLiveEstimate = true
    /// 离屏渲染（TU_HEADLESS）跳过入场动画，否则截图会抓到半透明中间帧
    @State private var appeared = ProcessInfo.processInfo.environment["TU_HEADLESS"] != nil
    /// GLM 月度消耗图的悬停月份（与其他图表的 hoverDay 独立，互不干扰）
    @State private var glmHoverMonth: Date?

    init(provider: AIProvider, range: UsageRange) {
        self.provider = provider
        self.range = range
        _keySelectionRaw = AppStorage(wrappedValue: "", "keySelection.\(provider.rawValue)")
        _accountSelectionRaw = AppStorage(wrappedValue: "", "accountSelection.\(provider.rawValue)")
        _cardMode = AppStorage(wrappedValue: "detailed", "cardMode.\(provider.rawValue)")
    }

    private var providerAccounts: [ProviderAccount] { store.accounts(for: provider) }
    private var providerKeys: [ProviderKey] { store.keys(for: provider) }

    /// 账户多选的原始选择；nil = 从未设置（默认全部），空集 = 全不勾（卡片放空）
    private var selectedAccountIDs: Set<String>? {
        get {
            guard !accountSelectionRaw.isEmpty,
                  let data = accountSelectionRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue else { accountSelectionRaw = ""; return }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            accountSelectionRaw = String(decoding: data, as: UTF8.self)
        }
    }

    /// 当前可见账户：nil = 全部账户合并；空集 = 全不勾（放空）；其余 = 勾选的 ∩ 现有账户
    private var visibleAccounts: [ProviderAccount] {
        guard let selection = selectedAccountIDs else { return providerAccounts }
        return providerAccounts.filter { selection.contains($0.id.uuidString) }
    }

    /// 账户多选下拉的当前值文案
    private var accountSelectionTitle: String {
        guard let selection = selectedAccountIDs else { return "全部" }
        let valid = providerAccounts.filter { selection.contains($0.id.uuidString) }
        if valid.isEmpty { return "未选择" }
        if valid.count == 1 { return valid[0].name }
        return "已选 \(valid.count) 个"
    }

    /// 简洁模式：只看所选时间段消耗与剩余
    private var isSimple: Bool { cardMode == "simple" }

    /// 配额布局：配额制服务商恒为真——除非它一个配额快照都没有但有余额数据
    ///（GLM 按量计费账号就是这种：quota 接口回退到了余额接口）；
    /// 自定义接口服务商在 Key 拿到配额快照时切换
    private var quotaLayout: Bool {
        if provider.usesQuota {
            let keys = visibleAccounts.flatMap { store.keys(for: $0) }
            if keys.contains(where: { store.quota(for: $0) != nil }) { return true }
            let hasBalance = keys.contains { store.data(for: $0)?.latest != nil }
            return !hasBalance
        }
        guard provider.usesCustomEndpoint else { return false }
        let keys = visibleAccounts.flatMap { store.keys(for: $0) }
        return !keys.isEmpty && keys.allSatisfy { store.quota(for: $0) != nil }
    }

    /// 用户在 Key 多选中的原始选择；nil = 从未设置（默认全部），空集 = 全不勾（放空）
    private var selectedKeyNames: Set<String>? {
        get {
            guard !keySelectionRaw.isEmpty,
                  let data = keySelectionRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue else { keySelectionRaw = ""; return }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            keySelectionRaw = String(decoding: data, as: UTF8.self)
        }
    }

    private var visibleKeys: [ProviderKey] {
        visibleAccounts.flatMap { store.keys(for: $0) }
    }

    /// 模型原始名 → 短展示名：去厂商前缀与版本段，避免图例名称过长被截断。
    /// deepseek-v4-flash → flash；deepseek-v4-pro → pro；deepseek-chat → chat；
    /// deepseek-chat & deepseek-reasoner → chat & reasoner
    static func displayModelName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "deepseek-", with: "", options: .caseInsensitive)
        let parts = name.split(separator: "-", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased().hasPrefix("v"),
           parts[0].dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            name = String(parts[1])
        }
        return name
    }

    /// 月粒度的 x 轴刻度标签：2025/3（带年份，跨年不歧义）
    private static let monthAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M"
        return formatter
    }()

    /// GLM 月度账单字符串解析："2026-08" → Date（月初）
    private static let glmMonthParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// GLM 月度图 tooltip 标题：2026年8月
    private static let glmTooltipMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    // MARK: - 聚合快照（性能关键）

    /// 单个模型一节的预聚合数据
    private struct ModelAgg {
        let model: String
        let sparkValues: [Double]
        let tokensItems: [DaySeriesStat]
        let tokensOrder: [String]
        let tokensTotal: String
        let tokensLegend: [String: String]
        let requestsItems: [DaySeriesStat]
        let requestsTotal: String
    }

    /// 单账户看板的预聚合数据
    private struct AccountAgg {
        let rangeConsumption: Double
        let rangeTokens: Int64
        let rangeTokensHasEstimate: Bool
        let showTokens: Bool
        let totalSpend: Double
        let balance: Double
    }

    /// 一次 body 求值内全看板共享的聚合快照。
    /// 性能关键：此前图表/统计卡/余额卡全是各自独立的 computed property，
    /// 每次访问都全量扫描 usageRecords 并重算实时估算——一次渲染重复几十遍；
    /// hover 图例时 InteractiveChartCard 的重渲染闭包又会整套重算，指针扫过即卡。
    /// 现在 body 顶部算一次，下游视图与闭包统一读这份值类型快照。
    private struct Agg {
        var scopedRecords: [UsageRecord] = []
        var hasRecords = false
        var models: [String] = []
        var keyNames: [String] = []
        var rangedModels: [String] = []
        var menuKeyNames: [String] = []
        var effectiveKeys: Set<String>?
        var selectedKeysByAccount: [UUID: [ProviderKey]] = [:]
        var hasLiveSpend = false
        var bucketUnit: Calendar.Component = .day
        // 合计余额卡
        var rangeConsumption = 0.0
        var rangeTokens: Int64 = 0
        var rangeTokensHasEstimate = false
        var totalSpend = 0.0
        var totalBalance = 0.0
        var perAccount: [UUID: AccountAgg] = [:]
        // 统计卡
        var statCost = 0.0
        var statRequests: Int64 = 0
        var statRequestsApprox = false
        var statTokens: Int64 = 0
        var statTokensSubtitle: String?
        var statTypeTokens: [String: Double] = [:]
        // 消费金额图
        var costItems: [DaySeriesStat] = []
        var costSpanItems: [StackedBarChart.SpanStat] = []
        var costSeriesOrder: [String] = []
        var costLegendValues: [String: Double] = [:]
        // Tokens 图（实时估算 / 小时粒度真实记录）
        var liveTokensItems: [DaySeriesStat] = []
        var tokensSpanItems: [StackedBarChart.SpanStat] = []
        var liveTokensOrder: [String] = []
        var liveTokensTotal = ""
        var liveTokensLegend: [String: String] = [:]
        var showLiveTokens = false
        // 每模型一节（非小时粒度）
        var modelSections: [ModelAgg] = []
    }

    /// 构建全看板共享的聚合快照。每次 body 求值只跑一遍，
    /// 下游统计卡 / 余额卡 / 图表 / 图例闭包全部读这份结果。
    private func makeAgg() -> Agg {
        var agg = Agg()
        let start = range.startDate
        let end = range.endDate
        let calendar = Calendar.current

        // Key → 系列名映射（平台 Key 名优先，其次本地标签）；同时得到 Key 多选菜单项
        var seriesNameByID: [UUID: String] = [:]
        var seen = Set<String>()
        for key in visibleKeys {
            let name = store.importedKeyName(for: key) ?? key.label
            seriesNameByID[key.id] = name
            if seen.insert(name).inserted { agg.menuKeyNames.append(name) }
        }
        // 当前生效的 Key 多选（nil = 全部；空集 = 全不勾，看板放空）；
        // 已选但不属于可见账户的 Key 名自动失效（交集剔除）
        agg.effectiveKeys = selectedKeyNames?.intersection(agg.menuKeyNames)
        let keyFilter = agg.effectiveKeys
        func keySelected(_ key: ProviderKey) -> Bool {
            keyFilter?.contains(seriesNameByID[key.id] ?? key.label) ?? true
        }
        for account in visibleAccounts {
            agg.selectedKeysByAccount[account.id] = store.keys(for: account).filter(keySelected)
        }

        // 可见账户的导入记录（限定本服务商的可见账户；模型名统一转短展示名）
        let accountIDs = Set(visibleAccounts.map(\.id))
        let scoped = store.usageRecords.compactMap { record -> UsageRecord? in
            guard record.accountID.map({ accountIDs.contains($0) }) ?? false else { return nil }
            var r = record
            r.model = Self.displayModelName(r.model)
            return r
        }
        agg.scopedRecords = scoped
        agg.hasRecords = !scoped.isEmpty
        agg.models = scoped.models
        agg.keyNames = scoped.keyNames
        // 所选时间段内真正有数据的模型（区间内零用量的模型不出 section，避免空图表占位）
        agg.rangedModels = scoped.filter {
            $0.day >= start && $0.day < end
                && ($0.totalTokens > 0 || $0.requests > 0 || $0.cost > 0)
                && (keyFilter?.contains($0.apiKeyName) ?? true)
        }.models
        agg.bucketUnit = chartBucketUnit(for: scoped)

        // 实时消耗事件（各账户覆盖边界之后；保留时间戳与 Key 归属）
        var liveStartByAccount: [UUID: Date] = [:]
        var liveItems: [(date: Date, key: ProviderKey, amount: Double)] = []
        for account in visibleAccounts {
            let liveStart = store.liveStart(forAccountID: account.id)
            liveStartByAccount[account.id] = liveStart
            for key in store.keys(for: account) {
                for event in (store.data(for: key)?.consumptionEvents(since: liveStart) ?? []) {
                    liveItems.append((date: event.date, key: key, amount: event.amount))
                }
            }
        }
        agg.hasLiveSpend = !liveItems.isEmpty
        let filteredLive = liveItems.filter {
            $0.date >= start && $0.date < end && keySelected($0.key)
        }
        let rangedLiveCost = filteredLive.reduce(0.0) { $0 + $1.amount }

        // 各 Key 的实时估算口径（最近一天优先；统计卡 / 消费图 / Tokens 图共用）
        var profiles: [UUID: LiveProfile] = [:]
        for key in visibleKeys {
            profiles[key.id] = liveProfile(for: key, scoped: scoped,
                                           seriesName: seriesNameByID[key.id] ?? key.label)
        }
        let rangedLiveTokens = filteredLive.reduce(0.0) {
            $0 + $1.amount * (profiles[$1.key.id]?.tokensPerYuan ?? 0)
        }

        // 各账户与合并口径（所选时间段消耗 / Tokens / 累计消费 / 剩余余额）
        for account in visibleAccounts {
            let accountRecords = scoped.forAccount(account.id)
            let selectedKeys = agg.selectedKeysByAccount[account.id] ?? []
            let selectedIDs = Set(selectedKeys.map(\.id))
            let liveStart = liveStartByAccount[account.id] ?? .distantPast
            let liveSince = max(liveStart, start)
            let liveCost = liveSince < end
                ? liveItems.filter {
                    $0.key.accountID == account.id && selectedIDs.contains($0.key.id)
                        && $0.date >= liveSince && $0.date < end
                  }.reduce(0.0) { $0 + $1.amount }
                : 0
            // tokens/元 口径：该账户最近一个有数据的自然日的实际比率，无则退化为账户全历史
            var ratio = 0.0
            if let latest = accountRecords.map(\.day).max() {
                let latestDay = accountRecords.filter { calendar.isDate($0.day, inSameDayAs: latest) }
                ratio = Self.tokensPerYuanRatio(in: latestDay, keyNames: keyFilter)
            }
            if ratio == 0 {
                ratio = Self.tokensPerYuanRatio(in: accountRecords, keyNames: keyFilter)
            }
            let tokens = accountRecords.totalTokens(since: start, until: end, keyNames: keyFilter)
                + Int64(liveCost * ratio)
            let importedAll = accountRecords.totalCost(since: .distantPast, keyNames: keyFilter)
            let liveAll = liveItems.filter {
                $0.key.accountID == account.id && selectedIDs.contains($0.key.id)
            }.reduce(0.0) { $0 + $1.amount }
            agg.perAccount[account.id] = AccountAgg(
                rangeConsumption: accountRecords.totalCost(since: start, until: end, keyNames: keyFilter) + liveCost,
                rangeTokens: tokens,
                rangeTokensHasEstimate: liveCost > 0 && ratio > 0,
                showTokens: !accountRecords.isEmpty || tokens > 0,
                totalSpend: (account.cumulativeBase ?? 0) + importedAll + liveAll,
                balance: selectedKeys.compactMap { store.data(for: $0)?.latest?.totalBalance }.reduce(0, +)
            )
        }
        agg.rangeConsumption = visibleAccounts.reduce(0.0) { $0 + (agg.perAccount[$1.id]?.rangeConsumption ?? 0) }
        agg.rangeTokens = visibleAccounts.reduce(0) { $0 + (agg.perAccount[$1.id]?.rangeTokens ?? 0) }
        agg.rangeTokensHasEstimate = visibleAccounts.contains { agg.perAccount[$0.id]?.rangeTokensHasEstimate == true }
        agg.totalSpend = visibleAccounts.reduce(0.0) { $0 + (agg.perAccount[$1.id]?.totalSpend ?? 0) }
        agg.totalBalance = visibleAccounts.reduce(0.0) { $0 + (agg.perAccount[$1.id]?.balance ?? 0) }

        // 统计卡：消费金额 / API 请求次数 / Tokens + 类型拆分（实时部分按各 Key 口径估算）
        agg.statCost = scoped.totalCost(since: start, until: end, keyNames: keyFilter) + rangedLiveCost
        let liveReqs = filteredLive.reduce(0.0) {
            $0 + $1.amount * (profiles[$1.key.id]?.requestsPerYuan ?? 0)
        }
        agg.statRequests = scoped.totalRequests(since: start, until: end, keyNames: keyFilter) + Int64(liveReqs)
        agg.statRequestsApprox = liveReqs >= 0.5
        agg.statTokens = scoped.totalTokens(since: start, until: end, keyNames: keyFilter) + Int64(rangedLiveTokens)
        agg.statTokensSubtitle = (agg.hasRecords || agg.rangeTokens > 0)
            ? "\(agg.rangeTokensHasEstimate ? "≈ " : "")\(range == .today ? "今日" : range.title) Tokens \(Formatting.tokens(Double(agg.rangeTokens)))"
            : nil
        let rangedTypes = scoped.tokensByType(since: start, until: end, keyNames: keyFilter)
        for type in UsageRecord.tokenTypeOrder {
            let live = filteredLive.reduce(0.0) { sum, spend in
                let profile = profiles[spend.key.id] ?? LiveProfile()
                return sum + spend.amount * profile.tokensPerYuan * (profile.typeShares[type] ?? 0)
            }
            agg.statTypeTokens[type] = Double(rangedTypes[type] ?? 0) + live
        }

        // 消费金额图（模型 / API Key 双维度堆叠）：
        // 逐小时/逐天真实记录 + 覆盖截止后的实时消耗（Key 维度按系列名归属；
        // 模型维度逐事件按该 Key 最近一天的模型消费占比分摊，无可参照口径的进兜底系列）
        var costItems = range.isHourly
            ? (costChartByKey
                ? scoped.hourlyByKey(since: start, until: end, keyNames: keyFilter)
                : scoped.hourlyByModel(since: start, until: end, keyNames: keyFilter))
            : (costChartByKey
                ? scoped.dailyByKey(since: start, until: end, keyNames: keyFilter)
                : scoped.dailyByModel(since: start, until: end, keyNames: keyFilter))
        if costChartByKey {
            costItems += filteredLive.map {
                DaySeriesStat(day: bucketStart(for: $0.date),
                              series: seriesNameByID[$0.key.id] ?? $0.key.label, cost: $0.amount)
            }
        } else {
            var perBucketModel: [Date: [String: Double]] = [:]
            var perBucketFallback: [Date: Double] = [:]
            for spend in filteredLive {
                let bucket = bucketStart(for: spend.date)
                let shares = profiles[spend.key.id]?.modelShares ?? [:]
                if shares.isEmpty {
                    perBucketFallback[bucket, default: 0] += spend.amount
                } else {
                    for (model, share) in shares where share > 0 {
                        perBucketModel[bucket, default: [:]][model, default: 0] += spend.amount * share
                    }
                }
            }
            for (bucket, modelCosts) in perBucketModel {
                for (model, cost) in modelCosts {
                    costItems.append(DaySeriesStat(day: bucket, series: model, cost: cost))
                }
            }
            costItems += perBucketFallback.map {
                DaySeriesStat(day: $0.key, series: Self.liveModelSeries, cost: $0.value)
            }
        }
        agg.costItems = chartItems(costItems, unit: agg.bucketUnit)

        // 小时粒度的导入合计跨幅柱（天粒度记录拆不到小时，00:00 → 覆盖边界半透明呈现）
        if range.isHourly {
            let coverageMax = visibleAccounts.map { liveStartByAccount[$0.id] ?? .distantPast }.max() ?? .distantPast
            let spanEnd = min(coverageMax, end)
            if spanEnd > start {
                let dayLevel = scoped.filter { $0.isDayGranular }
                let names = costChartByKey
                    ? dayLevel.keyNames.filter { keyFilter?.contains($0) ?? true }
                    : dayLevel.models
                agg.costSpanItems = names.compactMap { name in
                    let total = costChartByKey
                        ? dayLevel.totalCost(since: start, until: end, keyNames: [name])
                        : dayLevel.totalCost(since: start, until: end, model: name, keyNames: keyFilter)
                    guard total > 0 else { return nil }
                    return StackedBarChart.SpanStat(start: start, end: spanEnd, series: name, value: total)
                }
                let dayTypes = dayLevel.tokensByType(since: start, until: end, keyNames: keyFilter)
                agg.tokensSpanItems = UsageRecord.tokenTypeOrder.compactMap { type in
                    let value = Double(dayTypes[type] ?? 0)
                    guard value > 0 else { return nil }
                    return StackedBarChart.SpanStat(start: start, end: spanEnd, series: type, value: value)
                }
            }
        }

        // 系列顺序（模型序或 Key 序 + 实时系列，过滤掉无数据的）与图例合计值
        let presentSeries = Set(agg.costItems.map(\.series) + agg.costSpanItems.map(\.series))
        let importedOrder = (costChartByKey ? agg.keyNames : agg.models).filter { presentSeries.contains($0) }
        if costChartByKey {
            // 只有实时数据的 Key 追加在导入系列之后（去重保序）
            var extra: [String] = []
            for spend in filteredLive {
                let name = seriesNameByID[spend.key.id] ?? spend.key.label
                if !importedOrder.contains(name) && !extra.contains(name) { extra.append(name) }
            }
            agg.costSeriesOrder = importedOrder + extra.filter { presentSeries.contains($0) }
        } else {
            agg.costSeriesOrder = presentSeries.contains(Self.liveModelSeries)
                ? importedOrder + [Self.liveModelSeries] : importedOrder
        }
        for name in agg.costSeriesOrder {
            let imported = costChartByKey
                ? scoped.totalCost(since: start, until: end, keyNames: [name])
                : scoped.totalCost(since: start, until: end, model: name, keyNames: keyFilter)
            let live: Double
            if costChartByKey {
                live = filteredLive
                    .filter { (seriesNameByID[$0.key.id] ?? $0.key.label) == name }
                    .reduce(0.0) { $0 + $1.amount }
            } else if name == Self.liveModelSeries {
                // 兜底系列：没有可参照口径的 Key 的实时消耗
                live = filteredLive.reduce(0.0) {
                    (profiles[$1.key.id]?.modelShares.isEmpty ?? true) ? $0 + $1.amount : $0
                }
            } else {
                // 模型维度：实时消耗按各 Key 自己的占比分摊进各模型
                live = filteredLive.reduce(0.0) {
                    $0 + $1.amount * (profiles[$1.key.id]?.modelShares[name] ?? 0)
                }
            }
            agg.costLegendValues[name] = imported + live
        }

        // Tokens 图：实时估算逐事件按类型拆分；小时粒度叠加官网同步的逐小时真实记录
        var perBucketType: [Date: [String: Double]] = [:]
        for spend in filteredLive {
            let bucket = bucketStart(for: spend.date)
            let profile = profiles[spend.key.id] ?? LiveProfile()
            for type in UsageRecord.tokenTypeOrder {
                let tokens = spend.amount * profile.tokensPerYuan * (profile.typeShares[type] ?? 0)
                if tokens > 0 { perBucketType[bucket, default: [:]][type, default: 0] += tokens }
            }
        }
        var tokensItems: [DaySeriesStat] = perBucketType.sorted { $0.key < $1.key }.flatMap { day, types in
            UsageRecord.tokenTypeOrder.compactMap { type in
                guard let value = types[type], value > 0 else { return nil }
                return DaySeriesStat(day: day, series: type, tokens: value)
            }
        }
        var hourlyTokens: [DaySeriesStat] = []
        if range.isHourly {
            hourlyTokens = scoped.hourlyByTokenType(since: start, until: end, keyNames: keyFilter)
            tokensItems += hourlyTokens
        }
        agg.liveTokensItems = chartItems(tokensItems, unit: agg.bucketUnit)
        let presentTypes = Set(agg.liveTokensItems.map(\.series) + agg.tokensSpanItems.map(\.series))
        agg.liveTokensOrder = UsageRecord.tokenTypeOrder.filter { presentTypes.contains($0) }
        let importedTokensTotal = rangedTypes.values.reduce(0, +)
        agg.liveTokensTotal = range.isHourly
            ? "\(Formatting.tokens(Double(importedTokensTotal)))\(rangedLiveTokens > 0 ? " + ≈ \(Formatting.tokens(rangedLiveTokens))" : "")"
            : "≈ \(Formatting.tokens(rangedLiveTokens))"
        for type in agg.liveTokensOrder {
            let live = filteredLive.reduce(0.0) { sum, spend in
                let profile = profiles[spend.key.id] ?? LiveProfile()
                return sum + spend.amount * profile.tokensPerYuan * (profile.typeShares[type] ?? 0)
            }
            if range.isHourly {
                let imported = Double(rangedTypes[type] ?? 0)
                agg.liveTokensLegend[type] = "\(Formatting.tokens(imported))\(live > 0 ? " + ≈ \(Formatting.tokens(live))" : "")"
            } else {
                agg.liveTokensLegend[type] = "≈ \(Formatting.tokens(live))"
            }
        }
        agg.showLiveTokens = rangedLiveTokens > 0 || !agg.tokensSpanItems.isEmpty || !hourlyTokens.isEmpty

        // 每模型一节（小时粒度视图不出）：Tokens 类型堆叠图 + 请求次数面积图 + 迷你趋势
        if !range.isHourly {
            // dailyByModel 一次聚合全模型，各节自行过滤（此前每模型各聚一遍）
            let dailyModelAll = chartItems(
                scoped.dailyByModel(since: start, until: end, keyNames: keyFilter), unit: agg.bucketUnit
            )
            for model in agg.rangedModels {
                let tokensItems = chartItems(
                    scoped.dailyByTokenType(since: start, until: end, model: model, keyNames: keyFilter),
                    unit: agg.bucketUnit
                )
                let present = Set(tokensItems.map(\.series))
                let types = scoped.tokensByType(since: start, until: end, model: model, keyNames: keyFilter)
                let order = UsageRecord.tokenTypeOrder.filter { (types[$0] ?? 0) > 0 }
                var legend: [String: String] = [:]
                for type in order { legend[type] = Formatting.tokens(Double(types[type] ?? 0)) }
                let requestsItems = dailyModelAll.filter { $0.series == model }
                agg.modelSections.append(ModelAgg(
                    model: model,
                    sparkValues: requestsItems.map(\.tokens),
                    tokensItems: tokensItems,
                    tokensOrder: UsageRecord.tokenTypeOrder.filter { present.contains($0) },
                    tokensTotal: Formatting.grouped(
                        scoped.totalTokens(since: start, until: end, model: model, keyNames: keyFilter)
                    ),
                    tokensLegend: legend,
                    requestsItems: requestsItems,
                    requestsTotal: Formatting.grouped(
                        scoped.totalRequests(since: start, until: end, model: model, keyNames: keyFilter)
                    )
                ))
            }
        }
        return agg
    }

    var body: some View {
        // 全看板聚合快照：每次 body 求值只算一遍，下游所有模块共用（性能关键）
        let agg = makeAgg()
        return VStack(alignment: .leading, spacing: 10) {
            titleRow
            if providerAccounts.isEmpty {
                missingKeyRow
            } else if isSimple {
                simpleContent(agg)
            } else {
                detailedContent(agg)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.smooth(duration: 0.45), value: appeared)
        .animation(.smooth(duration: 0.35), value: isSimple)
        .onAppear { appeared = true }
    }

    /// 简洁模式：只保留筛选行与「时间段消耗 + 剩余余额」（配额制为各 Key 剩余百分比的一行流）。
    /// 账户 / Key 多选仍然生效并可见，方便随时切换口径。
    @ViewBuilder
    private func simpleContent(_ agg: Agg) -> some View {
        if providerAccounts.count > 1 || !agg.menuKeyNames.isEmpty { controlRow(agg) }
        if visibleAccounts.isEmpty {
            selectionEmptyHint("账户")
        } else if agg.effectiveKeys?.isEmpty == true {
            selectionEmptyHint("API Key")
        } else if !visibleKeys.isEmpty {
            if quotaLayout {
                ForEach(visibleAccounts) { account in
                    if visibleAccounts.count > 1 { accountHeader(account) }
                    ForEach(store.keys(for: account)) { key in
                        quotaCompactRow(key)
                    }
                }
            } else if showBalanceCard {
                balanceCard(agg: agg, simple: true)
            }
        }
    }

    /// 详细模式：完整看板（余额卡 + 各账户卡 + Key 行 + 统计卡 + 图表）
    @ViewBuilder
    private func detailedContent(_ agg: Agg) -> some View {
        if providerAccounts.count > 1 || !agg.menuKeyNames.isEmpty { controlRow(agg) }
        if visibleAccounts.isEmpty {
            selectionEmptyHint("账户")
        } else if agg.effectiveKeys?.isEmpty == true {
            selectionEmptyHint("API Key")
        } else {
            if !visibleKeys.isEmpty {
                if quotaLayout {
                    // 配额制：每个 Key 一张额度卡
                    ForEach(visibleAccounts) { account in
                        if visibleAccounts.count > 1 { accountHeader(account) }
                        if showKeyRows {
                            ForEach(store.keys(for: account)) { key in
                                QuotaKeyRow(provider: provider, providerKey: key)
                            }
                        }
                    }
                } else {
                    if showBalanceCard { balanceCard(agg: agg, simple: false) }
                    ForEach(visibleAccounts) { account in
                        if visibleAccounts.count > 1 && showAccountCards {
                            accountCard(agg: agg, account: account)
                        }
                        if showKeyRows {
                            ForEach(agg.selectedKeysByAccount[account.id] ?? []) { key in
                                // 自定义接口可能返回配额快照：按 Key 实际数据形态选行样式
                                if store.quota(for: key) != nil {
                                    QuotaKeyRow(provider: provider, providerKey: key)
                                } else {
                                    KeyUsageRow(provider: provider, providerKey: key, range: range)
                                }
                            }
                        }
                    }
                }
            }
            // GLM 按量计费：官方账单区（累计消费/充值/赠送 + 本月按模型 + 月度历史），
            // 都是控制台财务接口的精确值，不走用量估算那套
            if provider == .glm, !quotaLayout {
                glmBillingSection
            }
            // 用量区：任何有记录的服务商都显示统计卡与图表；无数据时按服务商给引导
            if agg.hasRecords || agg.hasLiveSpend {
                usageSection(agg)
            } else if provider == .deepseek {
                importHintRow
            } else if provider == .mimo {
                mimoSyncHintRow
            }
            if provider == .deepseek, let error = store.importError {
                importErrorRow(error)
            }
        }
    }

    /// 多选全不勾时的空态提示（下拉仍可见，可重新勾选）
    private func selectionEmptyHint(_ what: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
            Text("未选择\(what)：在上方下拉中勾选要展示的\(what)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - 标题行

    private var titleRow: some View {
        HStack(spacing: 6) {
            PulsingDot(color: provider.accentColor, active: store.isRefreshing)
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if provider == .deepseek { importButton }
            Button {
                cardMode = isSimple ? "detailed" : "simple"
            } label: {
                Text(isSimple ? "详细" : "简洁")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.scale)
            .help(isSimple ? "切换到详细视图" : "切换到简洁视图（只看所选时间段消耗与剩余）")
            if let consoleURL = provider.consoleURL {
                Link(destination: consoleURL) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .help("打开平台控制台")
            }
        }
    }

    /// 导入口径：可见账户唯一时直接导入；多账户时先选目标账户
    @ViewBuilder
    private var importButton: some View {
        if visibleAccounts.count == 1, let target = visibleAccounts.first {
            Button {
                importUsageZIP(into: target)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.scale)
            .help("导入 DeepSeek 用量导出 ZIP 到「\(target.name)」")
        } else {
            Menu {
                ForEach(visibleAccounts) { account in
                    Button("导入到「\(account.name)」") { importUsageZIP(into: account) }
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择要导入用量数据的账户")
        }
    }

    private func importUsageZIP(into account: ProviderAccount) {
        // LSUIElement 应用未激活时 NSOpenPanel 可能不弹出/落到后面，先激活
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        store.importUsage(from: url, into: account)
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - 控制行（显示模式 / 账户选择 / Key 多选）

    /// 控制行：多账户时出现账户多选下拉；有本地 Key 时出现 API Key 多选。
    /// 两个多选都驱动看板的所有数据动态变化。
    private func controlRow(_ agg: Agg) -> some View {
        HStack(spacing: 8) {
            if providerAccounts.count > 1 { accountFilterMenu }
            if !agg.menuKeyNames.isEmpty { keyFilterMenu(agg) }
            Spacer()
        }
        .animation(.smooth(duration: 0.3), value: visibleAccounts.map(\.id.uuidString))
    }

    /// 账户多选下拉：原生勾选标识；勾一个看一个，勾多个合并看所选；
    /// 「全部」是总开关——勾上 = 全部展示，取消 = 全不勾（卡片放空）；
    /// 逐项勾满全部时自动归一为默认「全部」
    private var accountFilterMenu: some View {
        Menu {
            Toggle("全部", isOn: Binding(
                get: { selectedAccountIDs == nil },
                set: { on in selectedAccountIDs = on ? nil : [] }
            ))
            Divider()
            ForEach(providerAccounts) { account in
                Toggle(account.name, isOn: Binding(
                    get: { selectedAccountIDs?.contains(account.id.uuidString) ?? true },
                    set: { _ in toggleAccountSelection(account.id.uuidString) }
                ))
            }
        } label: {
            // Menu label 只完整渲染单个 Text（HStack 多元素会被拍扁），名称与当前值拼接
            (Text("账户 ").foregroundStyle(.secondary)
                + Text(accountSelectionTitle).fontWeight(.medium))
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 切换单个账户的勾选：在默认「全部」上点击 = 取消勾选它（其余全选）；
    /// 勾满全部时归一化为默认（nil）；全部取消 = 空集，卡片放空
    private func toggleAccountSelection(_ id: String) {
        let all = Set(providerAccounts.map(\.id.uuidString))
        var selection = selectedAccountIDs ?? all
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        selectedAccountIDs = selection == all ? nil : selection
    }

    /// Key 多选下拉的当前值文案
    private func keySelectionTitle(_ agg: Agg) -> String {
        guard let selection = selectedKeyNames else { return "全部" }
        let valid = selection.intersection(agg.menuKeyNames)
        if valid.isEmpty { return "未选择" }
        if valid.count == 1, let only = valid.first { return only }
        return "已选 \(valid.count) 个"
    }

    /// API Key 多选下拉：只列可见账户的 Key；原生勾选标识，语义同账户多选
    /// （「全部」为总开关；全部取消 = 空集，看板放空）
    private func keyFilterMenu(_ agg: Agg) -> some View {
        Menu {
            Toggle("全部", isOn: Binding(
                get: { selectedKeyNames == nil },
                set: { on in selectedKeyNames = on ? nil : [] }
            ))
            Divider()
            ForEach(agg.menuKeyNames, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { selectedKeyNames?.contains(name) ?? true },
                    set: { _ in toggleKeySelection(agg, name) }
                ))
            }
        } label: {
            // Menu label 只完整渲染单个 Text（HStack 多元素会被拍扁），名称与当前值拼接
            (Text("API Key ").foregroundStyle(.secondary)
                + Text(keySelectionTitle(agg)).fontWeight(.medium))
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 切换单个 Key 的勾选（语义同账户多选）
    private func toggleKeySelection(_ agg: Agg, _ name: String) {
        let all = Set(agg.menuKeyNames)
        var selection = selectedKeyNames ?? all
        if selection.contains(name) {
            selection.remove(name)
        } else {
            selection.insert(name)
        }
        selectedKeyNames = selection == all ? nil : selection
    }

    /// 合并视图下配额制账户的小标题（账户名 + 本周剩余额度百分比）。
    /// 金额制账户改用 accountCard（与顶部合并看板同布局）。
    private func accountHeader(_ account: ProviderAccount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "person.crop.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(account.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // 本周剩余百分比：次数口径与纯百分比口径统一走 weeklyRemainingPercent，多 Key 取平均
            let percents = store.keys(for: account).compactMap { store.quota(for: $0)?.weeklyRemainingPercent }
            let shown = percents.isEmpty ? 0 : percents.reduce(0, +) / percents.count
            Text("本周剩 \(shown)%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    /// 简洁模式下配额制 Key 的一行式摘要：Key 名 + 本周剩 % + 窗口剩 %
    private func quotaCompactRow(_ key: ProviderKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(key.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            if let quota = store.quota(for: key) {
                Text("本周剩 \(quota.weeklyRemainingPercent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("窗口剩 \(quota.windowRemainingPercent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let error = store.data(for: key)?.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                ShimmerView()
                    .frame(width: 72, height: 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .interactiveCardBackground(cornerRadius: 8)
    }

    // MARK: - 实时消耗（余额快照差额，补足导入覆盖截止时间之后的数据）

    /// 实时消耗的兜底系列名：仅在没有导入模型可供分摊时，模型维度图才单列此系列
    private static let liveModelSeries = "实时消耗"

    /// 实时消耗在模型维度图中的颜色
    private static let liveSeriesColor = Color.secondary

    /// 实时事件在所选时间段下的分桶起点：今天/昨天按小时，其余按天
    private func bucketStart(for date: Date) -> Date {
        if range.isHourly {
            return Calendar.current.dateInterval(of: .hour, for: date)?.start
                ?? Calendar.current.startOfDay(for: date)
        }
        return Calendar.current.startOfDay(for: date)
    }

    /// 「全部」出图粒度：按月；数据跨度超过 36 个月时按年（柱子更少、刻度推断更快）。
    /// 其他维度不聚合（按天；今天/昨天按小时，由图表的 hourly 区分）。
    private func chartBucketUnit(for records: [UsageRecord]) -> Calendar.Component {
        guard range == .all else { return .day }
        let days = records.map(\.day)
        guard let earliest = days.min(), let latest = days.max() else { return .month }
        let months = Calendar.current.dateComponents([.month], from: earliest, to: latest).month ?? 0
        return months > 36 ? .year : .month
    }

    /// 「全部」维度出图前把逐日数据按月/年聚合（见 chartBucketUnit：
    /// 长日期域上逐日柱既看不清也让 Swift Charts 刻度推断变慢——切换卡顿主因）。
    /// 其他维度原样返回。
    private func chartItems(_ items: [DaySeriesStat], unit: Calendar.Component) -> [DaySeriesStat] {
        guard range == .all else { return items }
        let calendar = Calendar.current
        var buckets: [String: DaySeriesStat] = [:]
        for item in items {
            let start = calendar.dateInterval(of: unit, for: item.day)?.start
                ?? calendar.startOfDay(for: item.day)
            let id = "\(start.timeIntervalSince1970)|\(item.series)"
            var agg = buckets[id] ?? DaySeriesStat(day: start, series: item.series)
            agg.tokens += item.tokens
            agg.requests += item.requests
            agg.cost += item.cost
            buckets[id] = agg
        }
        return buckets.values.sorted { ($0.day, $0.series) < ($1.day, $1.series) }
    }

    /// 单个 Key 的实时估算口径。余额快照只有总金额、没有模型/token 明细，
    /// 覆盖边界后的实时消耗按该 Key「最近一个有数据的自然日」的真实口径推断：
    /// 模型消费占比、tokens/元、请求/元与 token 类型占比。
    /// 不用全历史口径：账户切换模型后旧模型占大头，会把新消耗摊给不再使用的旧模型
    ///（今天视图冒出没用过的 pro / chat & reasoner 就是全历史口径造成的）。
    struct LiveProfile {
        var modelShares: [String: Double] = [:]   // 模型维度按消费金额占比
        var tokensPerYuan: Double = 0
        var requestsPerYuan: Double = 0
        var typeShares: [String: Double] = [:]    // token 类型按 tokens 占比
        var isEmpty: Bool { modelShares.isEmpty && tokensPerYuan == 0 }
    }

    /// 口径候选：Key 最近一天 → Key 全历史 → 账户最近一天 → 账户全历史 → 可见范围全历史，
    /// 第一个有消费/用量数据的胜出（Key 对不上导入名时自动退化到账户口径）
    private func liveProfile(for key: ProviderKey, scoped: [UsageRecord], seriesName: String) -> LiveProfile {
        let own = scoped.filter { $0.apiKeyName == seriesName }
        let accountRecords = scoped.filter { $0.accountID == key.accountID }
        var candidates: [[UsageRecord]] = []
        if let latest = own.map(\.day).max() {
            candidates.append(own.filter { Calendar.current.isDate($0.day, inSameDayAs: latest) })
        }
        candidates.append(own)
        if let latest = accountRecords.map(\.day).max() {
            candidates.append(accountRecords.filter { Calendar.current.isDate($0.day, inSameDayAs: latest) })
        }
        candidates.append(accountRecords)
        candidates.append(scoped)
        for records in candidates {
            let profile = Self.profile(from: records)
            if !profile.isEmpty { return profile }
        }
        return LiveProfile()
    }

    /// 由一组记录计算估算口径（模型占比按金额，token 类型占比按 tokens）
    private static func profile(from records: [UsageRecord]) -> LiveProfile {
        var profile = LiveProfile()
        let cost = records.totalCost(since: .distantPast)
        if cost > 0 {
            var shares: [String: Double] = [:]
            for model in records.models {
                let modelCost = records.totalCost(since: .distantPast, model: model)
                if modelCost > 0 { shares[model] = modelCost / cost }
            }
            profile.modelShares = shares
            profile.tokensPerYuan = Double(records.totalTokens(since: .distantPast)) / cost
            profile.requestsPerYuan = Double(records.totalRequests(since: .distantPast)) / cost
        }
        let types = records.tokensByType(since: .distantPast)
        let typeSum = Double(types.values.reduce(0, +))
        if typeSum > 0 {
            profile.typeShares = types.mapValues { Double($0) / typeSum }
        }
        return profile
    }

    /// tokens/元 比率（0 = 无消费数据可参照）
    private static func tokensPerYuanRatio(in records: [UsageRecord], keyNames: Set<String>?) -> Double {
        let cost = records.totalCost(since: .distantPast, keyNames: keyNames)
        guard cost > 0 else { return 0 }
        return Double(records.totalTokens(since: .distantPast, keyNames: keyNames)) / cost
    }

    /// 消耗/余额看板布局：左列所选时间段消耗（大数字）+ 时间段 Tokens + 累计消费，右列剩余余额。
    /// 左右两个大数字同字号同字重，剩余余额与消耗金额一样醒目。
    /// simple = 简洁模式：只保留时间段消耗与剩余余额两个大数字。
    /// 顶部合并看板与各账户看板共用同一布局。
    private func spendCard(consumption: Double, tokens: Int64, hasEstimate: Bool, showTokens: Bool,
                           spend: Double, balance: Double, simple: Bool = false) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(range == .today ? "今日消耗" : "\(range.title)消耗")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Formatting.cny(consumption))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(provider.accentColor)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.4), value: consumption)
                    Text(store.currency(for: provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 时间段 tokens：导入真实值 + 覆盖截止后按历史比率估算的实时部分，跟随所选时间维度
                if !simple, showTokens {
                    Text("\(hasEstimate ? "≈ " : "")\(range == .today ? "今日" : range.title) Tokens \(Formatting.grouped(tokens))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.4), value: tokens)
                }
                if !simple {
                    MaskedAmount(label: "累计消费", amount: spend)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .animation(.smooth(duration: 0.4), value: spend)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("剩余余额")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Formatting.cny(balance))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.4), value: balance)
                    Text(store.currency(for: provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interactiveCardBackground()
    }

    // MARK: - 余额卡（时间段消耗 + 时间段 Tokens + 累计消费 + 剩余余额；合并与单账户共用布局）

    private func balanceCard(agg: Agg, simple: Bool) -> some View {
        spendCard(
            consumption: agg.rangeConsumption,
            tokens: agg.rangeTokens,
            hasEstimate: agg.rangeTokensHasEstimate,
            showTokens: agg.hasRecords || agg.rangeTokens > 0,
            spend: agg.totalSpend,
            balance: agg.totalBalance,
            simple: simple
        )
    }

    /// 单账户看板：账户名 + 与顶部合并看板相同的布局与口径
    private func accountCard(agg: Agg, account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                    .font(.caption2)
                Text(account.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
            if let accountAgg = agg.perAccount[account.id] {
                spendCard(
                    consumption: accountAgg.rangeConsumption,
                    tokens: accountAgg.rangeTokens,
                    hasEstimate: accountAgg.rangeTokensHasEstimate,
                    showTokens: accountAgg.showTokens,
                    spend: accountAgg.totalSpend,
                    balance: accountAgg.balance
                )
            }
        }
    }

    // MARK: - GLM 账单区（按量计费账号：控制台财务接口的官方数据）

    /// 可见 GLM Key 的合并账单。
    /// 注意：智谱账单接口按「账户」出数，同一账户配多把 Key 时各 Key 返回相同数据，
    /// 合并口径与面板其他模块一致（直接相加），单 Key/单账户场景即精确值。
    private var glmBillingMerged: GLMBillingInfo? {
        let infos = visibleKeys.compactMap { store.glmBilling(for: $0) }
        guard !infos.isEmpty else { return nil }
        if infos.count == 1 { return infos[0] }
        var byModel: [String: (amount: Double, tokens: Int64)] = [:]
        var monthly: [String: Double] = [:]
        for info in infos {
            for m in info.byModel {
                let cur = byModel[m.model] ?? (0, 0)
                byModel[m.model] = (cur.amount + m.amount, cur.tokens + m.tokens)
            }
            for m in info.monthly { monthly[m.month] = (monthly[m.month] ?? 0) + m.amount }
        }
        return GLMBillingInfo(
            updatedAt: infos.map(\.updatedAt).max() ?? Date(),
            totalSpend: infos.reduce(0) { $0 + $1.totalSpend },
            rechargeAmount: infos.reduce(0) { $0 + $1.rechargeAmount },
            giveAmount: infos.reduce(0) { $0 + $1.giveAmount },
            monthAmount: byModel.values.reduce(0) { $0 + $1.amount },
            monthTokens: byModel.values.reduce(0) { $0 + $1.tokens },
            byModel: byModel.map { .init(model: $0.key, amount: $0.value.amount, tokens: $0.value.tokens) }
                .sorted { $0.amount > $1.amount },
            monthly: monthly.map { .init(month: $0.key, amount: $0.value) }.sorted { $0.month < $1.month }
        )
    }

    @ViewBuilder
    private var glmBillingSection: some View {
        if let billing = glmBillingMerged {
            VStack(spacing: 8) {
                // 账户累计（官方口径，不用手动校准）
                HStack(spacing: 8) {
                    statCard(title: "累计消费", value: Formatting.cny(billing.totalSpend), unit: nil,
                             subtitle: nil, dot: provider.accentColor)
                    statCard(title: "累计充值", value: Formatting.cny(billing.rechargeAmount), unit: nil)
                    statCard(title: "累计赠送", value: Formatting.cny(billing.giveAmount), unit: nil)
                }
                // 本月消耗 + 按模型明细
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("本月消耗")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Formatting.cny(billing.monthAmount))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(provider.accentColor)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("CNY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("本月 Tokens")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Formatting.grouped(billing.monthTokens))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(billing.byModel) { m in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(provider.accentColor)
                                .frame(width: 5, height: 5)
                            Text(Self.displayModelName(m.model))
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Formatting.grouped(m.tokens)) tokens")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(Formatting.cny(m.amount))
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(10)
                .interactiveCardBackground()
                // 月度消耗历史
                if billing.monthly.count > 1 {
                    let monthlyItems = billing.monthly.compactMap { m -> (date: Date, amount: Double)? in
                        guard let d = Self.glmMonthParser.date(from: m.month) else { return nil }
                        return (d, m.amount)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("月度消耗")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Chart(monthlyItems, id: \.date) { item in
                            BarMark(
                                x: .value("月份", item.date, unit: .month),
                                y: .value("金额", item.amount)
                            )
                            .foregroundStyle(provider.accentColor)
                            .cornerRadius(3)
                            .opacity(glmHoverMonth == nil || item.date == glmHoverMonth ? 1 : 0.55)
                            if let glmHoverMonth {
                                RuleMark(x: .value("月份", glmHoverMonth, unit: .month))
                                    .foregroundStyle(Color.secondary.opacity(0.25))
                                    .lineStyle(StrokeStyle(lineWidth: 1))
                            }
                        }
                        .chartLegend(.hidden)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                AxisValueLabel {
                                    if let date = value.as(Date.self) {
                                        Text(Self.monthAxisFormatter.string(from: date))
                                            .font(.system(size: 9))
                                    }
                                }
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text(Formatting.compactCNY(v))
                                            .font(.system(size: 9))
                                    }
                                }
                                AxisGridLine()
                            }
                        }
                        .chartOverlay { proxy in
                            HoverTracker(proxy: proxy, day: glmHoverMonth,
                                         setDay: { glmHoverMonth = $0 }, bucketUnit: .month) {
                                if let month = glmHoverMonth,
                                   let item = monthlyItems.first(where: {
                                       Calendar.current.isDate($0.date, equalTo: month, toGranularity: .month)
                                   }) {
                                    ChartTooltip(
                                        day: month,
                                        rows: [.init(name: "消费金额", color: provider.accentColor,
                                                     text: Formatting.cny(item.amount))],
                                        title: Self.glmTooltipMonthFormatter.string(from: month)
                                    )
                                }
                            }
                        }
                        .frame(height: 90)
                    }
                    .padding(10)
                    .interactiveCardBackground()
                }
            }
        }
    }

    // MARK: - 导入用量区（DeepSeek 风格：筛选 → 统计卡 → 图表）

    /// 用量区：统计卡 → 消费金额图 → 各模型图 → 实时估算图（各模块可在设置中显隐）。
    /// 今天/昨天（小时粒度）：横轴固定 00:00–24:00；导入的当日合计以半透明跨幅柱呈现
    /// （平台导出按天聚合，拆不到小时），覆盖边界后的实时记录画逐小时细柱。
    private func usageSection(_ agg: Agg) -> some View {
        // GLM 按量计费：账单区（上方）已是官方精确数据；这里只保留余额差额驱动的
        // 消费金额图。请求次数 / Tokens 明细 / 模型图对 GLM 无数据来源，显示一排 0 反而像坏了
        let glmBalanceMode = provider == .glm && !quotaLayout
        return VStack(alignment: .leading, spacing: 10) {
            if showStatCards, !glmBalanceMode { statCardsRow(agg) }
            if showCostChart { costChartCard(agg) }
            if !glmBalanceMode, range.isHourly {
                hourlyCaption
            } else if !glmBalanceMode {
                if range == .all { aggregationCaption(agg) }
                if showModelCharts {
                    // 每个有数据的模型独立一节：Tokens 柱状图 + 请求次数面积图
                    ForEach(agg.modelSections, id: \.model) { section in
                        modelSection(agg, section)
                    }
                }
            }
            // Tokens 图：小时粒度 = 小时级导入记录逐小时柱 + 天粒度合计跨幅柱 + 实时估算；天粒度 = 仅实时估算
            if showLiveEstimate, agg.showLiveTokens, !glmBalanceMode {
                liveTokensCard(agg)
            }
        }
    }

    /// 小时粒度说明：逐小时柱来自官网同步，覆盖边界后的新消耗按小时实时追加
    private var hourlyCaption: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text("逐小时数据来自官网同步；同步之后的新消耗由 App 按小时实时追加")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// 「全部」聚合说明：按数据跨度按月 / 按年（超过 36 个月）
    private func aggregationCaption(_ agg: Agg) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(agg.bucketUnit == .year ? "数据跨度超过 36 个月，图表按年聚合" : "图表按月聚合")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// 三张主统计卡：消费金额（导入真实消费 + 截止日后实时推算，副标题为该时间段总 tokens）/
    /// API 请求次数 / Tokens（所选时间段口径；实时部分按各 Key 最近一天的 tokens/元 与 请求/元 口径估算，含估算时显示 ≈ 前缀）。
    /// 第二行：Tokens 按类型拆分明细（输入·命中 / 输入·未命中 / 输出）：
    /// 导入精确值 + 实时估算部分按各 Key 最近一天的类型占比分摊（今天/昨天等无导入的区间也不再是 0），
    /// 色点与图表系列同色。
    private func statCardsRow(_ agg: Agg) -> some View {
        let reqsValue = (agg.statRequestsApprox ? "≈ " : "") + Formatting.grouped(agg.statRequests)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                statCard(title: "消费金额", value: Formatting.cny(agg.statCost), unit: "CNY",
                         subtitle: agg.statTokensSubtitle)
                statCard(title: "API 请求次数", value: reqsValue, unit: nil, subtitle: nil)
                statCard(title: "Tokens", value: Formatting.grouped(agg.statTokens), unit: nil, subtitle: nil)
            }
            HStack(spacing: 8) {
                ForEach(UsageRecord.tokenTypeOrder, id: \.self) { type in
                    statCard(
                        title: type,
                        value: Formatting.tokens(agg.statTypeTokens[type] ?? 0),
                        unit: nil,
                        subtitle: nil,
                        dot: TokenTypeColors.color(for: type)
                    )
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: range)
        .animation(.smooth(duration: 0.4), value: agg.effectiveKeys)
    }

    private func statCard(title: String, value: String, unit: String?, subtitle: String? = nil,
                          dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.35), value: value)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.35), value: subtitle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interactiveCardBackground()
    }

    // MARK: 消费金额图（模型 / API Key 双维度堆叠）

    private func costColor(for series: String) -> Color {
        if costChartByKey { return KeyColors.color(for: series) }
        return series == Self.liveModelSeries ? Self.liveSeriesColor : ModelColors.color(for: series)
    }

    private func costChartCard(_ agg: Agg) -> some View {
        InteractiveChartCard(
            title: "消费金额（CNY）",
            // 合计 = 导入真实消费 + 实时推算；小时粒度下导入部分以跨幅柱呈现，口径一致
            total: Formatting.cny(agg.statCost)
        ) {
            // 模型 / API Key 切换（对齐 DeepSeek 的分段开关）
            Picker("", selection: $costChartByKey) {
                Text("模型").tag(false)
                Text("API Key").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 128)
        } chart: { highlight in
            StackedBarChart(
                items: agg.costItems,
                valueFor: { $0.cost },
                seriesOrder: agg.costSeriesOrder,
                colorFor: costColor,
                height: 150,
                valueFormatter: { Formatting.cny($0) },
                axisFormatter: { $0 < 10 ? String(format: "%.2f", $0) : Formatting.axisTokens($0) },
                highlight: highlight,
                hourly: range.isHourly,
                bucketUnit: agg.bucketUnit,
                xDomain: range.isHourly ? range.startDate...range.endDate : nil,
                emptyMessage: range.isHourly ? "该日暂无消耗数据" : "该时间段暂无消费数据",
                spanItems: agg.costSpanItems
            )
            // 时间维度切换时整体重建（.id）：避免 Swift Charts 在跨度悬殊的日期域之间
            // 逐帧插值（尤其「全部」：域跨数月，域变形动画是切换卡顿的主因）；
            // 重建后内部 grow 入场动画会重播，保留生长感
            .id(range)
            .animation(.smooth(duration: 0.5), value: agg.effectiveKeys)
            .animation(.smooth(duration: 0.5), value: agg.costItems.count)
        } legend: { hovered, setHovered in
            legendRow(
                names: agg.costSeriesOrder,
                colorFor: costColor,
                valueFor: { name in Formatting.cny(agg.costLegendValues[name] ?? 0) },
                hovered: hovered,
                onHover: setHovered
            )
        }
    }

    // MARK: 单个模型一节（Tokens 按类型堆叠 + 请求次数面积图）

    @ViewBuilder
    private func modelSection(_ agg: Agg, _ section: ModelAgg) -> some View {
        HStack(spacing: 8) {
            Text(section.model)
                .font(.subheadline.weight(.bold))
            Spacer()
            // 该模型在区间内的 tokens 趋势迷你图（「全部」按月/年聚合）
            SparklineView(
                values: section.sparkValues,
                lineColor: ModelColors.color(for: section.model)
            )
            .frame(width: 64, height: 14)
        }
        .padding(.top, 4)

        // Tokens：按类型（输入·命中 / 输入·未命中 / 输出）堆叠的用量柱状图（「全部」按月/年聚合）
        InteractiveChartCard(
            title: "Tokens",
            total: section.tokensTotal
        ) {
            EmptyView()
        } chart: { highlight in
            StackedBarChart(
                items: section.tokensItems,
                valueFor: { $0.tokens },
                seriesOrder: section.tokensOrder,
                colorFor: TokenTypeColors.color,
                height: 110,
                highlight: highlight,
                bucketUnit: agg.bucketUnit
            )
            // 时间维度切换整体重建，避免日期域变形动画卡顿（见消费金额图）
            .id(range)
            .animation(.smooth(duration: 0.5), value: agg.effectiveKeys)
        } legend: { hovered, setHovered in
            legendRow(
                names: UsageRecord.tokenTypeOrder.filter { section.tokensLegend[$0] != nil },
                colorFor: TokenTypeColors.color,
                valueFor: { name in section.tokensLegend[name] ?? "" },
                hovered: hovered,
                onHover: setHovered
            )
        }

        // API 请求次数：平滑面积图（模型色）
        InteractiveChartCard(
            title: "API 请求次数",
            total: section.requestsTotal
        ) {
            EmptyView()
        } chart: { _ in
            RequestsAreaChart(items: section.requestsItems, name: section.model,
                              color: ModelColors.color(for: section.model), height: 90,
                              bucketUnit: agg.bucketUnit)
                // 时间维度切换整体重建，避免日期域变形动画卡顿（见消费金额图）
                .id(range)
                .animation(.smooth(duration: 0.5), value: agg.effectiveKeys)
        } legend: { _, _ in
            EmptyView()
        }
    }

    /// Tokens 图：天粒度 = 实时估算（余额差额 × 各 Key 最近一天的 tokens/元，按类型占比拆分）；
    /// 小时粒度（今天/昨天）= 小时级导入记录逐小时柱 + 天粒度导入合计跨幅柱 + 实时估算
    private func liveTokensCard(_ agg: Agg) -> some View {
        InteractiveChartCard(
            title: range.isHourly ? "Tokens" : "Tokens（实时估算）",
            total: agg.liveTokensTotal
        ) {
            EmptyView()
        } chart: { highlight in
            StackedBarChart(
                items: agg.liveTokensItems,
                valueFor: { $0.tokens },
                seriesOrder: agg.liveTokensOrder,
                colorFor: TokenTypeColors.color,
                height: 110,
                highlight: highlight,
                hourly: range.isHourly,
                bucketUnit: agg.bucketUnit,
                xDomain: range.isHourly ? range.startDate...range.endDate : nil,
                emptyMessage: "该时段暂无消耗数据",
                spanItems: agg.tokensSpanItems
            )
            // 时间维度切换整体重建，避免日期域变形动画卡顿（见消费金额图）
            .id(range)
            .animation(.smooth(duration: 0.5), value: agg.effectiveKeys)
        } legend: { hovered, setHovered in
            legendRow(
                names: agg.liveTokensOrder,
                colorFor: TokenTypeColors.color,
                valueFor: { name in agg.liveTokensLegend[name] ?? "" },
                hovered: hovered,
                onHover: setHovered
            )
        }
    }

    /// 无导入数据时的引导（可见账户唯一时带上账户名）
    private var importHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
            Text(visibleAccounts.count == 1
                ? "「\(visibleAccounts[0].name)」暂无用量数据，点击右上角图标导入平台导出的 ZIP"
                : "暂无用量数据，点击右上角图标导入平台导出的 ZIP")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// 小米 MiMo 无同步数据时的引导（用量只能登录官网同步，无 ZIP 导入）
    private var mimoSyncHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            Text("暂无用量数据，在「设置」中登录小米 MiMo 官网，选择注册月份后自动同步")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func importErrorRow(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 图表构件

    /// 图例行：色点 + 名称 + 该系列在区间内的合计值，空间不够时自动换行（名称不截断）。
    /// 传入 hovered/onHover 时可交互：悬停某项高亮（其余淡出），并同步高亮图表中的对应系列。
    private func legendRow(names: [String], colorFor: @escaping (String) -> Color,
                           valueFor: @escaping (String) -> String,
                           hovered: String? = nil,
                           onHover: ((String?) -> Void)? = nil) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    Circle()
                        .fill(colorFor(name))
                        .frame(width: 6, height: 6)
                        .scaleEffect(hovered == name ? 1.35 : 1)
                    Text(name)
                        .font(.caption2)
                        .fontWeight(hovered == name ? .semibold : .regular)
                        .lineLimit(1)
                    Text(valueFor(name))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
                .opacity(hovered == nil || hovered == name ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { inside in onHover?(inside ? name : nil) }
            }
        }
        .foregroundStyle(.secondary)
        .animation(.smooth(duration: 0.2), value: hovered)
    }

    private var missingKeyRow: some View {
        HStack {
            Image(systemName: "key")
                .foregroundStyle(.secondary)
            Text("未配置 API Key，请在设置中添加")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// 敏感金额：默认显示 ***，鼠标悬停时显示真实数值
private struct MaskedAmount: View {
    let label: String
    let amount: Double
    @State private var hovering = false

    var body: some View {
        Text("\(label) \(hovering ? Formatting.cny(amount) : "***")")
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.25), value: hovering)
            .animation(.smooth(duration: 0.4), value: amount)
            .onHover { hovering = $0 }
    }
}

/// 图表卡片容器：标题 + 总值 + 可选头部控件 + 图表 + 可选图例。
/// 图例与图表共享 hoveredSeries：悬停图例项时图表中对应系列高亮、其余淡出。
private struct InteractiveChartCard<Header: View, ChartContent: View, Legend: View>: View {
    let title: String
    let total: String
    @ViewBuilder let header: () -> Header
    @ViewBuilder let chart: (String?) -> ChartContent
    @ViewBuilder let legend: (String?, @escaping (String?) -> Void) -> Legend
    @State private var hoveredSeries: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(total)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.35), value: total)
                }
                Spacer()
                header()
            }
            chart(hoveredSeries)
            legend(hoveredSeries, { hoveredSeries = $0 })
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interactiveCardBackground()
    }
}

/// 单个 Key 的用量行：所选时间段内的消耗。
/// 余额在账户看板与合并看板展示，Key 行不再重复；仅保留接口拉取失败的错误提示。
struct KeyUsageRow: View {
    let provider: AIProvider
    let providerKey: ProviderKey
    let range: UsageRange
    @EnvironmentObject private var store: BalanceStore

    private var data: ProviderData? { store.data(for: providerKey) }

    /// 该 Key 所属账户的实时起算边界（导入覆盖截止时刻；无导入数据则从头算起）
    private var liveBoundary: Date {
        store.liveStart(forAccountID: providerKey.accountID)
    }

    /// 所选时间段内的消耗：导入记录（平台 Key 名与本地标签映射匹配）+ 边界后的实时差额
    private var rangeSpend: Double {
        let imported = store.usageRecords
            .filter { $0.accountID == providerKey.accountID && $0.apiKeyName == store.importedKeyName(for: providerKey) }
            .totalCost(since: range.startDate, until: range.endDate)
        let live = data?.consumption(since: max(range.startDate, liveBoundary), until: range.endDate) ?? 0
        return imported + live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(providerKey.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let error = data?.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            if data?.latest != nil || rangeSpend > 0 {
                Text("\(range.title)消耗 \(Formatting.cny(rangeSpend, decimals: 3))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.smooth(duration: 0.4), value: range)
                    .animation(.smooth(duration: 0.4), value: rangeSpend)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .interactiveCardBackground(cornerRadius: 8)
    }
}

/// 单个 Key 的额度卡：周窗口 + 短窗口双进度条（剩余百分比 + 可选绝对次数）。
/// 次数口径（Kimi Code）显示绝对次数；纯百分比口径（Claude / Codex / GLM / MiniMax）只显示百分比。
struct QuotaKeyRow: View {
    let provider: AIProvider
    let providerKey: ProviderKey
    @EnvironmentObject private var store: BalanceStore

    private var quota: ProviderQuota? { store.quota(for: providerKey) }
    private var error: String? { store.data(for: providerKey)?.lastError }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(providerKey.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let quota {
                    if !quota.membershipTitle.isEmpty {
                        Text(quota.membershipTitle)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(provider.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(provider.accentColor)
                    }
                } else if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    ShimmerView()
                        .frame(width: 64, height: 14)
                }
            }

            if let quota {
                quotaBar(
                    title: "本周额度",
                    remainingPercent: quota.weeklyRemainingPercent,
                    usedRatio: quota.weeklyUsedRatio,
                    counts: quota.hasWeeklyCounts ? "\(quota.weeklyRemaining)/\(quota.weeklyLimit)" : nil,
                    reset: quota.weeklyReset,
                    resetWord: "重置"
                )
                quotaBar(
                    title: quota.windowDisplayTitle,
                    remainingPercent: quota.windowRemainingPercent,
                    usedRatio: quota.windowUsedRatio,
                    counts: quota.hasWindowCounts ? "\(quota.windowRemaining)/\(quota.windowLimit)" : nil,
                    reset: quota.windowReset,
                    resetWord: "恢复"
                )
                if quota.parallelLimit > 0 || quota.boosterEnabled {
                    HStack(spacing: 8) {
                        if quota.parallelLimit > 0 {
                            Text("并行上限 \(quota.parallelLimit)")
                        }
                        if quota.boosterEnabled {
                            Text("·")
                            Text("加量包本月 \(Formatting.cny(Double(quota.monthlyUsedCents) / 100))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .interactiveCardBackground(cornerRadius: 8)
    }

    private func quotaBar(title: String, remainingPercent: Int, usedRatio: Double,
                          counts: String?, reset: Date?, resetWord: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("剩 \(remainingPercent)%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let counts {
                    Text(counts)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: min(usedRatio, 1))
                .tint(usedRatio >= 0.9 ? .red : (usedRatio >= 0.8 ? .orange : provider.accentColor))
                .animation(.smooth(duration: 0.5), value: usedRatio)
            if let reset {
                HStack {
                    Spacer()
                    Text(reset, format: .dateTime.month(.defaultDigits).day().hour().minute())
                        + Text(" \(resetWord)")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 可交互图表（hover 显示当天明细）

/// 图表 hover 提示卡：日期（小时粒度时为 小时段）+ 各系列数值
private struct ChartTooltip: View {
    struct Row {
        let name: String
        let color: Color
        let text: String
    }

    let day: Date
    let rows: [Row]
    var hourly: Bool = false
    /// 自定义标题（如跨幅柱的「导入合计 00:00–09:22」）；nil 时按日期/小时默认格式
    var title: String? = nil

    /// 小时粒度提示卡标题：08-18 13:00（确定性格式，不受地区设置影响）
    private static let hourTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:00"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let title {
                    Text(title)
                } else if hourly {
                    Text(Self.hourTitleFormatter.string(from: day))
                } else {
                    Text(day, format: .dateTime.month(.defaultDigits).day(.defaultDigits).weekday(.abbreviated))
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 5, height: 5)
                    Text(row.name)
                        .font(.system(size: 9))
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(row.text)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .fixedSize()
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// hover 跟踪层：把鼠标 x 位置换算成分桶（天 / 小时）并悬浮提示卡。
/// 提示卡水平方向跟随光标，靠近边缘时收拢，避免超出图表。
private struct HoverTracker<Tooltip: View>: View {
    let proxy: ChartProxy
    let day: Date?
    let setDay: (Date?) -> Void
    var hourly: Bool = false
    /// 非小时粒度时的分桶单位：hover 命中归并到对应桶起点（天 / 月 / 年）
    var bucketUnit: Calendar.Component = .day
    @ViewBuilder let tooltip: () -> Tooltip

    var body: some View {
        GeometryReader { geo in
            // plot 区域在 overlay 坐标系中的位置（含 y 轴标签宽度）。
            // proxy.value(atX:) / position(forX:) 都以 plot 区域为原点，必须换算，
            // 否则 hover 命中的日期会向右偏移 y 轴标签的宽度（约两根柱子的距离）。
            let plotFrame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - plotFrame.origin.x
                            guard x >= 0, x <= plotFrame.width else {
                                if day != nil { setDay(nil) }
                                return
                            }
                            if let date: Date = proxy.value(atX: x) {
                                let bucket = Calendar.current.dateInterval(of: hourly ? .hour : bucketUnit, for: date)?.start
                                    ?? Calendar.current.startOfDay(for: date)
                                // 同一分桶内的连续 mouse-move 不更新状态：等值写 @State
                                // 同样会让 SwiftUI 失效重绘，是 hover 卡顿的源头之一
                                if bucket != day { setDay(bucket) }
                            }
                        case .ended:
                            if day != nil { setDay(nil) }
                        }
                    }
                if let day, let x = proxy.position(forX: day) {
                    tooltip()
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .position(
                            x: min(max(x + plotFrame.origin.x, 88), max(88, geo.size.width - 88)),
                            y: 44
                        )
                }
            }
            // 提示卡位置随分桶即时切换（不做位移动画）：跟随更直接，
            // 也避免指针扫动时位移动画不断重启、堆积 GPU 工作
        }
    }
}

/// 图例/标签用的流式布局：子项横向排列，超出可用宽度时自动换行（避免长名称被截断）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 按系列堆叠的日/小时用量柱状图（带坐标轴与 hover 明细，DeepSeek 图表样式）。
/// 首次出现柱子从 0 升起；悬停图例（highlight）或某分桶时其余系列 / 分桶淡出。
/// 非零分段有最小可见高度（峰值的 2%）：数据再小也能看到柱子，与「无数据」明确区分；
/// tooltip 仍显示真实数值。没有任何非零数据时显示空态占位。
/// spanItems：跨幅柱（如导入数据的当日合计，覆盖 00:00–导出时刻），半透明弱化显示，
/// 与逐小时细柱共存于小时轴上，hover 覆盖时段时提示「导入合计」。
private struct StackedBarChart: View {
    /// 跨幅柱数据：[start, end) 时段内某系列的合计值（导入按天聚合，无法拆到小时）
    struct SpanStat: Identifiable, Sendable {
        var id: String { "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(series)" }
        let start: Date
        let end: Date
        let series: String
        var value: Double
    }

    let items: [DaySeriesStat]
    let valueFor: (DaySeriesStat) -> Double
    let seriesOrder: [String]
    let colorFor: (String) -> Color
    var height: CGFloat = 150
    var valueFormatter: (Double) -> String = { Formatting.grouped(Int64($0)) }
    /// y 轴刻度格式化（金额图可传入小数友好的格式）
    var axisFormatter: (Double) -> String = { Formatting.axisTokens($0) }
    var highlight: String? = nil
    /// 小时粒度（今天/昨天）：x 轴按小时分桶，标签 HH:00
    var hourly: Bool = false
    /// 非小时粒度时的 x 轴分桶单位：天（默认）/ 月 / 年（「全部」长跨度聚合，
    /// 数据需已预聚合到桶起点；柱子更少、刻度推断更快，避免卡顿）
    var bucketUnit: Calendar.Component = .day
    /// 固定 x 轴区间（小时粒度时传当天的 00:00–24:00，无数据的时段也留出位置）
    var xDomain: ClosedRange<Date>? = nil
    var emptyMessage: String = "暂无数据"
    /// 跨幅柱（导入合计）；仅小时粒度视图使用
    var spanItems: [SpanStat] = []

    @State private var hoverDay: Date?
    @State private var grow: Double = 0

    /// 小时粒度的 x 轴刻度标签：00:00 / 06:00 …
    private static let hourAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        return formatter
    }()

    /// 月粒度的 x 轴刻度标签：2025/3（带年份，跨年不歧义）
    private static let monthAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M"
        return formatter
    }()

    /// 年粒度的 x 轴刻度标签：2025
    private static let yearAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    /// 同一天同系列的多条数据（导入 + 实时）合并为一条，并按（日期, 图例顺序）固定排序。
    /// 配合确定性 id，保证任何重算（hover、动画）下堆叠顺序不变。
    private var mergedItems: [DaySeriesStat] {
        var buckets: [String: DaySeriesStat] = [:]
        for item in items {
            if var existing = buckets[item.id] {
                existing.tokens += item.tokens
                existing.requests += item.requests
                existing.cost += item.cost
                buckets[item.id] = existing
            } else {
                buckets[item.id] = item
            }
        }
        let orderIndex = Dictionary(
            seriesOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return buckets.values.sorted {
            ($0.day, orderIndex[$0.series] ?? .max) < ($1.day, orderIndex[$1.series] ?? .max)
        }
    }

    /// 手动堆叠后的跨幅柱（yStart/yEnd 已含累计偏移）
    private struct StackedSpan: Identifiable {
        let span: SpanStat
        let yStart: Double
        let yEnd: Double
        var id: String { span.id }
    }

    /// 跨幅柱按（start,end）分组、按 seriesOrder 顺序自底向上手动堆叠
    private var stackedSpans: [StackedSpan] {
        var groups: [String: [SpanStat]] = [:]
        for span in spanItems {
            groups["\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)", default: []].append(span)
        }
        let orderIndex = Dictionary(
            seriesOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [StackedSpan] = []
        for spans in groups.values {
            var acc = 0.0
            for span in spans.sorted(by: {
                (orderIndex[$0.series] ?? .max) < (orderIndex[$1.series] ?? .max)
            }) {
                result.append(StackedSpan(span: span, yStart: acc, yEnd: acc + span.value))
                acc += span.value
            }
        }
        return result
    }

    /// 各分桶堆叠总量的峰值（真实值口径；跨幅柱按整段合计参与，保证 y 轴量程覆盖）
    private func maxBucketTotal(merged: [DaySeriesStat]) -> Double {
        var perBucket: [Date: Double] = [:]
        for item in merged { perBucket[item.day, default: 0] += valueFor(item) }
        var perSpan: [String: Double] = [:]
        for span in spanItems { perSpan["\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)", default: 0] += span.value }
        return max(perBucket.values.max() ?? 0, perSpan.values.max() ?? 0)
    }

    /// 绘制值：非零分段至少显示峰值的 2%，小数据也能看到柱子
    private func displayValue(for item: DaySeriesStat, maxTotal: Double) -> Double {
        let raw = valueFor(item)
        return raw > 0 ? max(raw, maxTotal * 0.02) : 0
    }

    var body: some View {
        // mergedItems / maxBucketTotal 一次求值后贯穿本次渲染
        //（否则 displayValue 逐柱重算峰值，O(n²)）
        let merged = mergedItems
        let maxTotal = maxBucketTotal(merged: merged)
        // 是否有任何非零数据（全零与空一样走空态占位）
        if maxTotal > 0 {
            chartBody(merged: merged, maxTotal: maxTotal)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func chartBody(merged: [DaySeriesStat], maxTotal: Double) -> some View {
        let chart = Chart {
            // 跨幅柱：导入数据的时段合计（半透明，与逐小时细柱区分）。
            // RectangleMark + 手动堆叠：范围 BarMark 不参与自动堆叠，多系列会重叠/漂浮
            ForEach(stackedSpans) { stacked in
                RectangleMark(
                    xStart: .value("开始", stacked.span.start),
                    xEnd: .value("结束", stacked.span.end),
                    yStart: .value("起", stacked.yStart * grow),
                    yEnd: .value("止", stacked.yEnd * grow)
                )
                .foregroundStyle(colorFor(stacked.span.series))
                .cornerRadius(2.5)
                .opacity(spanOpacity(for: stacked.span))
            }
            ForEach(merged) { item in
                BarMark(
                    x: .value("时间", item.day, unit: hourly ? .hour : bucketUnit),
                    y: .value("值", displayValue(for: item, maxTotal: maxTotal) * grow)
                )
                .foregroundStyle(by: .value("系列", item.series))
                .cornerRadius(2.5)
                .opacity(barOpacity(for: item))
            }
            if let hoverDay {
                RuleMark(x: .value("时间", hoverDay, unit: hourly ? .hour : bucketUnit))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale(domain: seriesOrder, range: seriesOrder.map { colorFor($0) })
        .chartLegend(.hidden)
        .chartXAxis {
            if hourly {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.hourAxisFormatter.string(from: date))
                                .font(.system(size: 9))
                        }
                    }
                }
            } else if bucketUnit == .month {
                // 月聚合：刻度带年份，避免跨年时只看 M/d 分不清是哪年
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.monthAxisFormatter.string(from: date))
                                .font(.system(size: 9))
                        }
                    }
                }
            } else if bucketUnit == .year {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.yearAxisFormatter.string(from: date))
                                .font(.system(size: 9))
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                        .font(.system(size: 9))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(axisFormatter(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            HoverTracker(proxy: proxy, day: hoverDay, setDay: { hoverDay = $0 }, hourly: hourly, bucketUnit: bucketUnit) {
                if let hoverDay {
                    ChartTooltip(day: hoverDay, rows: tooltipRows(on: hoverDay, merged: merged), hourly: hourly,
                                 title: tooltipTitle(on: hoverDay))
                }
            }
        }
        .frame(height: height)
        // hover 高亮 / 提示线不做数值动画：指针扫动时所有柱子会逐帧重插值（卡顿主因），
        // 即时切换更跟手；数据或筛选变化仍由调用方的 .animation(value:) 承担

        if let xDomain {
            chart.chartXScale(domain: xDomain)
                .onAppear {
                    withAnimation(.smooth(duration: 0.7)) { grow = 1 }
                }
        } else {
            chart
                .onAppear {
                    withAnimation(.smooth(duration: 0.7)) { grow = 1 }
                }
        }
    }

    /// 无数据占位：与图表同高，明确区分「无数据」与「数据太小看不见」
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.title3)
            Text(emptyMessage)
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            .quaternary.opacity(0.3),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func sameBucket(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(
            lhs, equalTo: rhs,
            toGranularity: hourly ? .hour : bucketUnit
        )
    }

    private func barOpacity(for item: DaySeriesStat) -> Double {
        if let highlight, item.series != highlight { return 0.2 }
        if let hoverDay, !sameBucket(item.day, hoverDay) { return 0.55 }
        return 1
    }

    /// 跨幅柱弱化显示（与逐小时细柱区分）；图例高亮 / hover 时段外进一步淡出
    private func spanOpacity(for span: SpanStat) -> Double {
        if let highlight, span.series != highlight { return 0.12 }
        if let hoverDay, !spanCovers(span, bucket: hoverDay) { return 0.25 }
        return 0.45
    }

    private func spanCovers(_ span: SpanStat, bucket: Date) -> Bool {
        bucket >= span.start && bucket < span.end
    }

    /// hover 时段命中的跨幅柱（若有）
    private func activeSpan(on bucket: Date) -> (start: Date, end: Date)? {
        spanItems.first { spanCovers($0, bucket: bucket) }.map { ($0.start, $0.end) }
    }

    private func tooltipRows(on bucket: Date, merged: [DaySeriesStat]) -> [ChartTooltip.Row] {
        // 命中跨幅柱：显示导入合计口径的各系列数值
        if let span = activeSpan(on: bucket) {
            return seriesOrder.map { name in
                let amount = spanItems
                    .filter { $0.series == name && $0.start == span.start && $0.end == span.end }
                    .reduce(0) { $0 + $1.value }
                return ChartTooltip.Row(name: name, color: colorFor(name), text: valueFormatter(amount))
            }
        }
        return seriesOrder.map { name in
            let amount = merged
                .filter { $0.series == name && sameBucket($0.day, bucket) }
                .reduce(0) { $0 + valueFor($1) }
            return ChartTooltip.Row(name: name, color: colorFor(name), text: valueFormatter(amount))
        }
    }

    /// 跨幅柱提示卡标题：导入合计 00:00–09:22
    private static let spanTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 月粒度提示卡标题：2025年3月
    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    /// 年粒度提示卡标题：2025年
    private static let yearTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年"
        return formatter
    }()

    private func tooltipTitle(on bucket: Date) -> String? {
        if let span = activeSpan(on: bucket) {
            return "导入合计 \(Self.spanTimeFormatter.string(from: span.start))–\(Self.spanTimeFormatter.string(from: span.end))"
        }
        switch bucketUnit {
        case .month:
            return Self.monthTitleFormatter.string(from: bucket)
        case .year:
            return Self.yearTitleFormatter.string(from: bucket)
        default:
            return nil
        }
    }
}

/// 平滑面积图（请求次数，DeepSeek 面积图样式，hover 显示当天数值）。
/// 首次出现从左向右擦除展开；悬停时显示当天数据点。
/// 只有 1 个数据点时折线画不出来，补一个明显的圆点；完全无数据时显示空态占位。
private struct RequestsAreaChart: View {
    let items: [DaySeriesStat]
    let name: String
    let color: Color
    var height: CGFloat = 90
    var emptyMessage: String = "暂无数据"
    /// 分桶单位：天（默认）/ 月 / 年（「全部」长跨度聚合，数据已预聚合到桶起点，hover 按桶匹配）
    var bucketUnit: Calendar.Component = .day

    @State private var hoverDay: Date?
    @State private var reveal: Double = 0

    private var hasData: Bool { items.contains { $0.requests > 0 } }

    /// hover 命中匹配：按分桶单位（天 / 月 / 年）
    private func sameBucket(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, equalTo: rhs, toGranularity: bucketUnit)
    }

    /// 提示卡标题：月/年粒度给「2025年3月」「2025年」；天粒度用默认（月日+星期）
    private func tooltipTitle(on bucket: Date) -> String? {
        switch bucketUnit {
        case .month: return Self.monthTitleFormatter.string(from: bucket)
        case .year: return Self.yearTitleFormatter.string(from: bucket)
        default: return nil
        }
    }

    /// 月粒度提示卡标题：2025年3月
    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    /// 年粒度提示卡标题：2025年
    private static let yearTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年"
        return formatter
    }()

    /// 月粒度 x 轴刻度：2025/3
    private static let monthAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M"
        return formatter
    }()

    /// 年粒度 x 轴刻度：2025
    private static let yearAxisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    var body: some View {
        if hasData {
            chartBody
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3)
                Text(emptyMessage)
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                .quaternary.opacity(0.3),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private var chartBody: some View {
        Chart {
            ForEach(items) { item in
                AreaMark(
                    x: .value("日期", item.day),
                    y: .value("次数", item.requests)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("日期", item.day),
                    y: .value("次数", item.requests)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // 单点数据折线不可见，补圆点
            if items.count == 1, let only = items.first {
                PointMark(
                    x: .value("日期", only.day),
                    y: .value("次数", only.requests)
                )
                .foregroundStyle(color)
                .symbolSize(40)
            }
            if let hoverDay {
                RuleMark(x: .value("日期", hoverDay))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let item = items.first(where: { sameBucket($0.day, hoverDay) }) {
                    PointMark(
                        x: .value("日期", item.day),
                        y: .value("次数", item.requests)
                    )
                    .foregroundStyle(color)
                    .symbolSize(28)
                }
            }
        }
        .chartXAxis {
            // 月/年聚合时带年份刻度，避免跨年只看 M/d 分不清是哪年
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        switch bucketUnit {
                        case .month:
                            Text(Self.monthAxisFormatter.string(from: date))
                                .font(.system(size: 9))
                        case .year:
                            Text(Self.yearAxisFormatter.string(from: date))
                                .font(.system(size: 9))
                        default:
                            Text(date, format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Formatting.axisTokens(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            HoverTracker(proxy: proxy, day: hoverDay, setDay: { hoverDay = $0 }, bucketUnit: bucketUnit) {
                if let hoverDay {
                    let requests = items.first(where: { sameBucket($0.day, hoverDay) })
                        .map(\.requests) ?? 0
                    ChartTooltip(
                        day: hoverDay,
                        rows: [ChartTooltip.Row(
                            name: name,
                            color: color,
                            text: Formatting.grouped(Int64(requests))
                        )],
                        title: tooltipTitle(on: hoverDay)
                    )
                }
            }
        }
        .frame(height: height)
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: max(0, geo.size.width * reveal))
            }
        }
        // hover 提示点即时切换，不做数值动画（指针扫动逐帧插值是卡顿主因）
        .onAppear {
            withAnimation(.smooth(duration: 0.8)) { reveal = 1 }
        }
    }
}

/// 数据加载中的微光扫过占位条。
struct ShimmerView: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.55), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: animate ? geo.size.width : -geo.size.width * 0.45)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}
