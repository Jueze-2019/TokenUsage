import Foundation

/// 一次余额快照（每次轮询记录一条）。
struct BalanceSnapshot: Codable, Identifiable, Sendable {
    var id: Date { timestamp }
    var timestamp: Date
    var totalBalance: Double
    var grantedBalance: Double   // 赠送余额
    var toppedUpBalance: Double  // 充值余额
    var currency: String
    var isAvailable: Bool
}

/// 某一天按余额下降量聚合的消耗（元）。
struct DailyConsumption: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let amount: Double
}

/// 配额制服务商的额度快照（无金额余额，按周/滚动窗口限量）。
/// 两种口径：
/// - 次数口径（Kimi Code）：weeklyLimit / weeklyUsed / windowLimit / windowUsed 为真实次数
/// - 百分比口径（Claude / Codex / GLM / MiniMax）：官方接口只给已用百分比，
///   存 weeklyUsedPercent / windowUsedPercent，不伪造次数
/// 新增可选字段对旧缓存解码兼容（synthesized Codable 对可选项自动 decodeIfPresent）。
struct ProviderQuota: Codable, Sendable {
    var timestamp: Date
    var membershipLevel: String   // LEVEL_INTERMEDIATE 等原始值
    var weeklyLimit: Int
    var weeklyUsed: Int
    var weeklyReset: Date?
    var windowMinutes: Int        // 滚动窗口长度（分钟），如 300 = 5 小时
    var windowLimit: Int
    var windowUsed: Int
    var windowReset: Date?
    var parallelLimit: Int
    var boosterEnabled: Bool      // Extra Usage（加量包）开关
    var monthlyUsedCents: Int     // 加量包本月已用（分）
    /// 周窗口已用百分比（0-100，纯百分比口径时非空）
    var weeklyUsedPercent: Double? = nil
    /// 短窗口已用百分比（0-100，纯百分比口径时非空）
    var windowUsedPercent: Double? = nil
    /// 套餐名补充（Codex plan_type / GLM 档位 / MiniMax 模型名等）
    var planName: String? = nil

    var weeklyRemaining: Int { max(0, weeklyLimit - weeklyUsed) }
    var windowRemaining: Int { max(0, windowLimit - windowUsed) }
    var weeklyUsedRatio: Double {
        if let percent = weeklyUsedPercent { return min(max(percent / 100, 0), 1) }
        return weeklyLimit > 0 ? Double(weeklyUsed) / Double(weeklyLimit) : 0
    }
    var windowUsedRatio: Double {
        if let percent = windowUsedPercent { return min(max(percent / 100, 0), 1) }
        return windowLimit > 0 ? Double(windowUsed) / Double(windowLimit) : 0
    }

    /// 周剩余百分比（0-100），优先纯百分比口径
    var weeklyRemainingPercent: Int {
        if let used = weeklyUsedPercent { return max(0, min(100, Int((100 - used).rounded()))) }
        return weeklyLimit > 0 ? weeklyRemaining * 100 / weeklyLimit : 0
    }

    /// 短窗口剩余百分比（0-100），优先纯百分比口径
    var windowRemainingPercent: Int {
        if let used = windowUsedPercent { return max(0, min(100, Int((100 - used).rounded()))) }
        return windowLimit > 0 ? windowRemaining * 100 / windowLimit : 0
    }

    /// 是否有真实次数（决定「剩余 X/Y」绝对次数小字是否展示）
    var hasWeeklyCounts: Bool { weeklyUsedPercent == nil && weeklyLimit > 0 }
    var hasWindowCounts: Bool { windowUsedPercent == nil && windowLimit > 0 }

    /// 短窗口展示名
    var windowDisplayTitle: String {
        windowMinutes % 60 == 0 ? "\(windowMinutes / 60) 小时窗口" : "\(windowMinutes) 分钟窗口"
    }

    /// 会员/套餐的展示名（planName 优先；原始值兜底：去掉 LEVEL_ 前缀）
    var membershipTitle: String {
        if let planName, !planName.isEmpty { return planName }
        switch membershipLevel {
        case "LEVEL_FREE": return "免费版"
        case "LEVEL_BASIC": return "基础会员"
        case "LEVEL_INTERMEDIATE": return "中级会员"
        case "LEVEL_ADVANCED": return "高级会员"
        case "LEVEL_PREMIUM": return "旗舰会员"
        default:
            return membershipLevel.replacingOccurrences(of: "LEVEL_", with: "")
        }
    }
}

/// 一个平台账户。同一服务商可有多个账号，API Key 与导入的用量数据都挂在账户下；
/// 看板支持按单个账户查看，也可全部账户合并查看。
struct ProviderAccount: Codable, Identifiable, Sendable {
    var id: UUID
    var provider: AIProvider
    var name: String
    /// 自定义查询接口地址（仅 mimo / custom 服务商使用；可选字段对旧数据解码兼容）
    var endpoint: String? = nil
    /// 累计消费校准基数（元）：注册至今的历史消费中、导入数据覆盖不到的部分，
    /// 由用户在设置中手动填入；看板的累计消费 = 校准基数 + 已导入 + 实时消耗。
    /// 可选字段对旧数据解码兼容；nil / 0 表示未校准。
    var cumulativeBase: Double? = nil
}

/// 一个 API Key 的元数据（Key 本身存本地 0600 文件，键名为 keychainAccount）。
struct ProviderKey: Codable, Identifiable, Sendable {
    var id: UUID
    var provider: AIProvider
    var label: String
    /// 所属账户。旧版数据无此字段，解码为随机占位后由 BalanceStore 归并到默认账户。
    var accountID: UUID

    var keychainAccount: String { "\(provider.rawValue).\(id.uuidString)" }

    init(id: UUID, provider: AIProvider, label: String, accountID: UUID) {
        self.id = id
        self.provider = provider
        self.label = label
        self.accountID = accountID
    }

    // 向后兼容：旧版存储的 Key 没有 accountID 字段
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(AIProvider.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label)
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID) ?? UUID()
    }
}

/// 用量统计的时间段（对齐 DeepSeek 平台的时间维度）。
enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case week
    case month
    case currentMonth
    case lastMonth
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .currentMonth: return "本月"
        case .lastMonth: return "上月"
        case .all: return "全部"
        }
    }

    /// 今天 / 昨天按小时（00:00–01:00 …）分桶出图；其余按天
    var isHourly: Bool { self == .today || self == .yesterday }

    var startDate: Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        switch self {
        case .today:
            return startOfToday
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        case .week:
            return Date().addingTimeInterval(-7 * 86_400)
        case .month:
            return Date().addingTimeInterval(-30 * 86_400)
        case .currentMonth:
            let comps = calendar.dateComponents([.year, .month], from: Date())
            return calendar.date(from: comps) ?? Date()
        case .lastMonth:
            let comps = calendar.dateComponents([.year, .month], from: Date())
            let thisMonth = calendar.date(from: comps) ?? Date()
            return calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        case .all:
            return .distantPast
        }
    }

    /// 区间结束（不含）。"上月"到本月 0 点，"昨天"到今天 0 点，其余延伸到明天 0 点（含今天）。
    var endDate: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: Date()).addingTimeInterval(86_400)
        switch self {
        case .yesterday:
            return calendar.startOfDay(for: Date())
        case .lastMonth:
            let comps = calendar.dateComponents([.year, .month], from: Date())
            return calendar.date(from: comps) ?? tomorrow
        default:
            return tomorrow
        }
    }
}

/// 某个 Key 的历史数据。
struct ProviderData: Codable, Sendable {
    var snapshots: [BalanceSnapshot] = []
    var lastError: String? = nil

    var latest: BalanceSnapshot? { snapshots.last }

    /// 从 date 起（至 until 前）的累计消耗（元）。用相邻快照的余额下降量累加，充值造成的上升不计。
    /// 会取 date 之前最近一条快照作为基线，因此跨窗口边界的消耗也能计入。
    /// 快照按写入即有序维护（loadCache 防御性排序 + 轮询追加天然升序），
    /// 读取热路径不再每次 O(n log n) 重排。
    func consumption(since date: Date, until: Date = .distantFuture) -> Double {
        var spend = 0.0
        for (prev, next) in zip(snapshots, snapshots.dropFirst())
        where next.timestamp >= date && next.timestamp < until {
            let delta = prev.totalBalance - next.totalBalance
            if delta > 0 { spend += delta }
        }
        return spend
    }

    /// 从 date 起（至 until 前）的逐条消耗事件（相邻快照的余额下降量，时间为后一条快照的时刻）。
    /// 与 consumption(since:) 同口径，但保留每次下降的时间点，供按天聚合进图表。
    /// 快照有序性的约定同 consumption(since:until:)。
    func consumptionEvents(since date: Date, until: Date = .distantFuture) -> [(date: Date, amount: Double)] {
        var events: [(date: Date, amount: Double)] = []
        for (prev, next) in zip(snapshots, snapshots.dropFirst())
        where next.timestamp >= date && next.timestamp < until {
            let delta = prev.totalBalance - next.totalBalance
            if delta > 0 { events.append((next.timestamp, delta)) }
        }
        return events
    }

    /// 按天聚合的消耗（用于柱状图），返回最近 days 天内有记录的数据，按时间升序。
    func dailyConsumption(days: Int = 30) -> [DailyConsumption] {
        let calendar = Calendar.current
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        var buckets: [Date: Double] = [:]
        for (prev, next) in zip(sorted, sorted.dropFirst()) {
            let delta = prev.totalBalance - next.totalBalance
            if delta > 0 {
                let day = calendar.startOfDay(for: next.timestamp)
                buckets[day, default: 0] += delta
            }
        }
        let cutoff = calendar.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86_400)
        return buckets
            .filter { $0.key >= cutoff }
            .sorted { $0.key < $1.key }
            .map { DailyConsumption(date: $0.key, amount: $0.value) }
    }
}

extension Array where Element == ProviderData {
    /// 将多个 Key 的余额历史按时间桶合并求和，得到"合计"趋势线（按时间升序）。
    func aggregatedBalanceHistory(bucketSeconds: Int = 600) -> [(date: Date, total: Double)] {
        var perBucket: [Int: (date: Date, sum: Double)] = [:]
        for data in self {
            // 每个 Key 在每个桶内取最后一条快照
            var lastInBucket: [Int: BalanceSnapshot] = [:]
            for snapshot in data.snapshots.sorted(by: { $0.timestamp < $1.timestamp }) {
                let bucket = Int(snapshot.timestamp.timeIntervalSince1970) / bucketSeconds
                lastInBucket[bucket] = snapshot
            }
            for (bucket, snapshot) in lastInBucket {
                let existing = perBucket[bucket] ?? (snapshot.timestamp, 0)
                perBucket[bucket] = (existing.date, existing.sum + snapshot.totalBalance)
            }
        }
        return perBucket
            .sorted { $0.key < $1.key }
            .map { (date: $0.value.date, total: $0.value.sum) }
    }
}

/// 一条导入的用量记录（某账户下某 Key 在某天某模型的 token 消耗与真实消费金额）。
struct UsageRecord: Codable, Sendable {
    var day: Date
    var model: String
    var apiKeyName: String
    var inputCacheHit: Int64
    var inputCacheMiss: Int64
    var output: Int64
    var requests: Int64
    /// 真实消费金额（元）：导出 CSV 中 price × amount 逐行累加
    var cost: Double
    /// 所属账户；nil 表示旧版导入的数据，启动时归并到 DeepSeek 默认账户
    var accountID: UUID?
    /// 导出 CSV 中的掩码 API Key（sk-abc***xyz）：用于本地 Key 与平台 Key 名的精确归属
    var apiKeyMask: String?
    /// 是否小时级记录（官网同步的单日查询返回逐小时桶）。
    /// 必须显式标记：00:00–01:00 的小时桶时间戳恰好等于当天 0 点，
    /// 靠「day 是否对齐 0 点」推断会把它误判成天级记录（今天/昨天图表出现巨型跨幅柱）
    var hourly: Bool = false

    var totalTokens: Int64 { inputCacheHit + inputCacheMiss + output }

    init(day: Date, model: String, apiKeyName: String,
         inputCacheHit: Int64, inputCacheMiss: Int64, output: Int64,
         requests: Int64, cost: Double = 0, accountID: UUID? = nil, apiKeyMask: String? = nil,
         hourly: Bool = false) {
        self.day = day
        self.model = model
        self.apiKeyName = apiKeyName
        self.inputCacheHit = inputCacheHit
        self.inputCacheMiss = inputCacheMiss
        self.output = output
        self.requests = requests
        self.cost = cost
        self.accountID = accountID
        self.apiKeyMask = apiKeyMask
        self.hourly = hourly
    }

    // 向后兼容：旧缓存的记录没有 cost / accountID / apiKeyMask / hourly 字段
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(Date.self, forKey: .day)
        model = try c.decode(String.self, forKey: .model)
        apiKeyName = try c.decode(String.self, forKey: .apiKeyName)
        inputCacheHit = try c.decodeIfPresent(Int64.self, forKey: .inputCacheHit) ?? 0
        inputCacheMiss = try c.decodeIfPresent(Int64.self, forKey: .inputCacheMiss) ?? 0
        output = try c.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        requests = try c.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        apiKeyMask = try c.decodeIfPresent(String.self, forKey: .apiKeyMask)
        // 旧缓存无 hourly 标记：非 0 点对齐的记录只可能来自官网逐小时同步，按时间戳推断；
        // 恰好 0 点的记录无法区分，保守按天级处理（下次同步后自愈）
        hourly = try c.decodeIfPresent(Bool.self, forKey: .hourly)
            ?? (day != Calendar.current.startOfDay(for: day))
    }
}

extension UsageRecord {
    /// token 类型维度的系列名与堆叠顺序（统计卡 / 柱状图 / 图例统一口径）
    static let tokenTypeHit = "输入·命中"
    static let tokenTypeMiss = "输入·未命中"
    static let tokenTypeOutput = "输出"
    static let tokenTypeOrder = [tokenTypeHit, tokenTypeMiss, tokenTypeOutput]

    /// 是否天粒度记录（ZIP 导入 / 官网月窗口按天聚合）；小时级记录以显式 hourly 标记为准
    var isDayGranular: Bool {
        !hourly
    }
}

/// 图表用：某天某系列（模型或 Key）的聚合值。
/// id 由 日期+系列 确定性生成：hover 触发视图重算时 id 保持稳定，
/// 否则 Swift Charts 会把柱子当作新数据重建，堆叠顺序来回颠倒。
struct DaySeriesStat: Identifiable, Sendable {
    var id: String { "\(day.timeIntervalSince1970)|\(series)" }
    let day: Date
    let series: String
    var tokens: Double = 0
    var requests: Double = 0
    var cost: Double = 0
}

extension Array where Element == UsageRecord {
    /// 按账户过滤（nil = 全部账户合并）
    func forAccount(_ accountID: UUID?) -> [UsageRecord] {
        guard let accountID else { return self }
        return filter { $0.accountID == accountID }
    }

    /// 去重排序后的模型列表
    var models: [String] {
        let names: [String] = map { $0.model }
        return [String](Set(names)).sorted()
    }

    /// 去重排序后的 Key 名列表
    var keyNames: [String] {
        let names: [String] = map { $0.apiKeyName }
        return [String](Set(names)).sorted()
    }

    private func filtered(since start: Date, until end: Date,
                          model: String? = nil, keyNames: Set<String>? = nil) -> [UsageRecord] {
        filter {
            $0.day >= start && $0.day < end
                && (model == nil || $0.model == model)
                && (keyNames?.contains($0.apiKeyName) ?? true)
        }
    }

    /// 按天 × 模型聚合，可选按 Key 多选过滤，按时间升序。
    /// 小时级记录（官网同步的今天/昨天）归并到当天，天维度图表不受影响。
    func dailyByModel(since start: Date, until end: Date = .distantFuture,
                      keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        dailyStats(filtered(since: start, until: end, keyNames: keyNames),
                   bucket: { Calendar.current.startOfDay(for: $0.day) }) { $0.model }
    }

    /// 按天 × Key 聚合，可选按模型 / Key 多选过滤，按时间升序
    func dailyByKey(since start: Date, until end: Date = .distantFuture,
                    model: String? = nil, keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        dailyStats(filtered(since: start, until: end, model: model, keyNames: keyNames),
                   bucket: { Calendar.current.startOfDay(for: $0.day) }) { $0.apiKeyName }
    }

    /// 按小时 × 模型聚合：只含小时级记录（官网同步的今天/昨天），供小时粒度图表
    func hourlyByModel(since start: Date, until end: Date,
                       keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        dailyStats(filtered(since: start, until: end, keyNames: keyNames).filter { !$0.isDayGranular },
                   bucket: \.day) { $0.model }
    }

    /// 按小时 × Key 聚合：只含小时级记录
    func hourlyByKey(since start: Date, until end: Date,
                     keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        dailyStats(filtered(since: start, until: end, keyNames: keyNames).filter { !$0.isDayGranular },
                   bucket: \.day) { $0.apiKeyName }
    }

    /// 按小时 × token 类型聚合：只含小时级记录
    func hourlyByTokenType(since start: Date, until end: Date,
                           keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        byTokenType(filtered(since: start, until: end, keyNames: keyNames).filter { !$0.isDayGranular },
                    bucket: \.day)
    }

    /// 按天 × token 类型（输入·命中 / 输入·未命中 / 输出）聚合，按时间升序。
    /// 小时级记录归并到当天。
    func dailyByTokenType(since start: Date, until end: Date = .distantFuture,
                          model: String? = nil, keyNames: Set<String>? = nil) -> [DaySeriesStat] {
        byTokenType(filtered(since: start, until: end, model: model, keyNames: keyNames),
                    bucket: { Calendar.current.startOfDay(for: $0.day) })
    }

    private func byTokenType(_ records: [UsageRecord],
                             bucket: (UsageRecord) -> Date) -> [DaySeriesStat] {
        records
            .flatMap { record in
                [
                    DaySeriesStat(day: bucket(record), series: UsageRecord.tokenTypeHit,
                                  tokens: Double(record.inputCacheHit)),
                    DaySeriesStat(day: bucket(record), series: UsageRecord.tokenTypeMiss,
                                  tokens: Double(record.inputCacheMiss)),
                    DaySeriesStat(day: bucket(record), series: UsageRecord.tokenTypeOutput,
                                  tokens: Double(record.output)),
                ]
            }
            .sorted { $0.day < $1.day }
    }

    /// 区间内各 token 类型的总量（key = 类型系列名，三种类型始终齐全）
    func tokensByType(since start: Date, until end: Date = .distantFuture,
                      model: String? = nil, keyNames: Set<String>? = nil) -> [String: Int64] {
        var result: [String: Int64] = [
            UsageRecord.tokenTypeHit: 0,
            UsageRecord.tokenTypeMiss: 0,
            UsageRecord.tokenTypeOutput: 0,
        ]
        for record in filtered(since: start, until: end, model: model, keyNames: keyNames) {
            result[UsageRecord.tokenTypeHit, default: 0] += record.inputCacheHit
            result[UsageRecord.tokenTypeMiss, default: 0] += record.inputCacheMiss
            result[UsageRecord.tokenTypeOutput, default: 0] += record.output
        }
        return result
    }

    private func dailyStats(_ records: [UsageRecord],
                            bucket: (UsageRecord) -> Date,
                            series: (UsageRecord) -> String) -> [DaySeriesStat] {
        var buckets: [String: DaySeriesStat] = [:]
        for record in records {
            let day = bucket(record)
            let id = "\(day.timeIntervalSince1970)|\(series(record))"
            var item = buckets[id] ?? DaySeriesStat(day: day, series: series(record))
            item.tokens += Double(record.totalTokens)
            item.requests += Double(record.requests)
            item.cost += record.cost
            buckets[id] = item
        }
        return buckets.values.sorted { $0.day < $1.day }
    }

    /// 区间内总 token 数，可选按模型 / Key 多选过滤
    func totalTokens(since start: Date, until end: Date = .distantFuture,
                     model: String? = nil, keyNames: Set<String>? = nil) -> Int64 {
        filtered(since: start, until: end, model: model, keyNames: keyNames)
            .map(\.totalTokens)
            .reduce(0, +)
    }

    /// 区间内总请求次数，可选按模型 / Key 多选过滤
    func totalRequests(since start: Date, until end: Date = .distantFuture,
                       model: String? = nil, keyNames: Set<String>? = nil) -> Int64 {
        filtered(since: start, until: end, model: model, keyNames: keyNames)
            .map(\.requests)
            .reduce(0, +)
    }

    /// 区间内真实消费金额（元），可选按模型 / Key 多选过滤
    func totalCost(since start: Date, until end: Date = .distantFuture,
                   model: String? = nil, keyNames: Set<String>? = nil) -> Double {
        filtered(since: start, until: end, model: model, keyNames: keyNames)
            .map(\.cost)
            .reduce(0, +)
    }
}

/// GLM 按量计费账号的账单信息（智谱控制台财务接口，按 Key 缓存，节流刷新）。
/// 这些维度是接口直接给的官方精确值，不参与余额差额估算。
struct GLMBillingInfo: Codable, Sendable {
    /// 本月按模型的消耗
    struct ModelSpend: Codable, Sendable, Identifiable {
        var id: String { model }
        var model: String
        var amount: Double   // 金额（元）
        var tokens: Int64    // tokens
    }
    /// 历史按月消耗（金额）
    struct MonthSpend: Codable, Sendable, Identifiable {
        var id: String { month }
        var month: String    // "2026-08"
        var amount: Double
    }
    var updatedAt: Date
    var totalSpend: Double      // 累计消费（注册至今，官方口径）
    var rechargeAmount: Double  // 累计充值
    var giveAmount: Double      // 累计赠送
    var monthAmount: Double     // 本月消费金额
    var monthTokens: Int64      // 本月 tokens
    var byModel: [ModelSpend] = []
    var monthly: [MonthSpend] = []
}

/// 通过 App Group 与小组件共享的缓存文件结构。
struct SharedCache: Codable, Sendable {
    var keys: [ProviderKey] = []
    var dataByKey: [String: ProviderData] = [:] // key = ProviderKey.id.uuidString
    var usageRecords: [UsageRecord] = []
    var quotaByKey: [String: ProviderQuota] = [:] // key = ProviderKey.id.uuidString（配额制服务商的额度）
    /// 各账户导入数据的精确覆盖截止时间（key = ProviderAccount.id.uuidString）。
    /// 实时消耗从该时刻起算：截止时刻（含）之前以导入数据为准，之后用余额快照差额推算。
    var usageCoverageEnd: [String: Date] = [:]
    /// GLM 按量计费账号的账单信息（key = ProviderKey.id.uuidString）
    var glmBilling: [String: GLMBillingInfo] = [:]
    var updatedAt: Date = Date()

    init() {}

    init(keys: [ProviderKey], dataByKey: [String: ProviderData], usageRecords: [UsageRecord] = [],
         quotaByKey: [String: ProviderQuota] = [:], usageCoverageEnd: [String: Date] = [:], updatedAt: Date) {
        self.keys = keys
        self.dataByKey = dataByKey
        self.usageRecords = usageRecords
        self.quotaByKey = quotaByKey
        self.usageCoverageEnd = usageCoverageEnd
        self.updatedAt = updatedAt
    }

    // 向后兼容：旧版缓存没有 usageRecords / quotaByKey / usageCoverageEnd / glmBilling 字段
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([ProviderKey].self, forKey: .keys) ?? []
        dataByKey = try container.decodeIfPresent([String: ProviderData].self, forKey: .dataByKey) ?? [:]
        usageRecords = try container.decodeIfPresent([UsageRecord].self, forKey: .usageRecords) ?? []
        quotaByKey = try container.decodeIfPresent([String: ProviderQuota].self, forKey: .quotaByKey) ?? [:]
        usageCoverageEnd = try container.decodeIfPresent([String: Date].self, forKey: .usageCoverageEnd) ?? [:]
        glmBilling = try container.decodeIfPresent([String: GLMBillingInfo].self, forKey: .glmBilling) ?? [:]
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 旧版（单 Key）缓存格式，仅用于迁移。
struct LegacySharedCache: Codable {
    var providers: [String: ProviderData]
    var updatedAt: Date
}
