import Foundation

enum UsageSyncError: LocalizedError {
    case notLoggedIn
    case invalidToken
    case badResponse(Int)
    case serverError(Int, String)
    case decodingFailed
    case noRecords

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "需要先登录 DeepSeek 官网账号"
        case .invalidToken: return "登录态已失效，请重新登录"
        case .badResponse(let code): return "请求失败 (HTTP \(code))"
        case .serverError(let code, let msg): return "接口返回错误 (\(code))\(msg.isEmpty ? "" : "：\(msg)")"
        case .decodingFailed: return "无法解析接口返回"
        case .noRecords: return "该时间段没有用量数据"
        }
    }
}

/// DeepSeek 官网（platform.deepseek.com）用量接口同步。
/// 接口需要网页登录态 userToken（Authorization: Bearer），一次查询最多 30 天；
/// 多天查询按天出桶，单日查询按小时出桶（今天/昨天可拿到真实逐小时数据）。
///
/// 端点（与官网用量页一致）：
///   GET /api/v0/usage/by_api_key/amount?start=<sec>&end=<sec>&tz=<sec>
///   GET /api/v0/usage/by_api_key/cost?start=<sec>&end=<sec>&tz=<sec>
/// 响应：{ data: { biz_data: { start, end, bucket, models, series / data … } } }
enum UsageSyncService {
    private static let base = "https://platform.deepseek.com"

    /// 同步进度回调（主线程）：阶段描述（如「2026-08」）
    typealias Progress = @Sendable (String) -> Void

    struct SyncResult {
        let records: [UsageRecord]
        let coverageEnd: Date
    }

    /// 轻量同步（今天/昨天逐小时）的结果
    struct RecentSyncResult {
        /// 成功拉取到的逐小时记录（已打 hourly 标记）
        let records: [UsageRecord]
        /// 成功拉取的自然日起点：只有这些天的旧记录允许被替换
        ///（某天拉取失败时保留现有数据，避免把已有记录误删成空）
        let fetchedDays: [Date]
        /// 今天的数据拉取成功时的同步时刻（用于推进实时估算的覆盖边界）；今天拉取失败为 nil
        let coverageEnd: Date?
    }

    // MARK: - 响应模型

    private struct AmountEnvelope: Decodable {
        let data: BizContainer?
        struct BizContainer: Decodable {
            let biz_data: BizData?
        }
        struct BizData: Decodable {
            let series: [Series]?
        }
        struct Series: Decodable {
            let api_key: ApiKey?
            let model: String?
            let buckets: [Bucket]?
        }
        struct ApiKey: Decodable {
            let tracking_id: String?
            let name: String?
            let sensitive_id: String?
        }
        struct Bucket: Decodable {
            let time: Double?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let PROMPT_CACHE_HIT_TOKEN: Double?
            let PROMPT_CACHE_MISS_TOKEN: Double?
            let RESPONSE_TOKEN: Double?
            let REQUEST: Double?
        }
    }

    private struct CostEnvelope: Decodable {
        let data: BizContainer?
        struct BizContainer: Decodable {
            let biz_data: BizData?
        }
        struct BizData: Decodable {
            let data: [CurrencyBlock]?
        }
        struct CurrencyBlock: Decodable {
            let currency: String?
            let series: [Series]?
        }
        struct Series: Decodable {
            let api_key: ApiKey?
            let model: String?
            let buckets: [Bucket]?
        }
        struct ApiKey: Decodable {
            let tracking_id: String?
            let name: String?
            let sensitive_id: String?
        }
        struct Bucket: Decodable {
            let time: Double?
            /// 官网返回的是字符串数字（如 "0.0508123000000000"）
            let cost: String?
        }
    }

    // MARK: - 同步入口

    /// 从注册月份 1 号起，按 ≤30 天一个窗口逐段拉取到今天；
    /// 今天与昨天再用单日查询拿小时级数据，替换月窗口里对应的天级记录。
    static func sync(fromMonth monthStart: Date, token: String,
                     progress: Progress? = nil) async throws -> SyncResult {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = startOfToday.addingTimeInterval(86_400)

        var all: [UsageRecord] = []
        var windowStart = calendar.startOfDay(for: monthStart)
        while windowStart < tomorrow {
            let windowEnd = min(
                calendar.date(byAdding: .day, value: 30, to: windowStart) ?? windowStart,
                tomorrow
            )
            progress?(Self.monthLabel(for: windowStart))
            all += try await fetchWindow(start: windowStart, end: windowEnd, token: token)
            windowStart = windowEnd
            // 官网接口有频率限制，窗口之间稍作停顿
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // 今天 / 昨天：单日查询拿小时级桶，替换掉月窗口里对应的天级记录
        for day in [startOfToday, calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday] {
            progress?("\(Self.monthLabel(for: day))（逐小时）")
            if let fetched = try? await fetchWindow(start: day, end: day.addingTimeInterval(86_400), token: token),
               !fetched.isEmpty {
                // 单日查询返回的是逐小时桶，显式打标——00:00 桶的时间戳恰好等于当天 0 点，
                // 不打标会被当成天级记录，小时图漏掉它、跨幅柱把它当全天合计
                let hourly = fetched.map { var record = $0; record.hourly = true; return record }
                all.removeAll { calendar.isDate($0.day, inSameDayAs: day) && $0.isDayGranular }
                all += hourly
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let records = all.sorted { $0.day < $1.day }
        guard !records.isEmpty else { throw UsageSyncError.noRecords }
        return SyncResult(records: records, coverageEnd: now)
    }

    private static func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// 轻量同步：只拉「今天 / 昨天」的单日逐小时数据（定时自动刷新用）。
    /// 有了它，今天/昨天维度的模型归属来自官网精确数据，而不是余额差额的占比估算
    ///（占比估算在账户切换模型后会把新消耗摊给不再使用的旧模型）。
    /// 登录态失效必须上抛，调用方据此停止自动同步；网络等错误只跳过当天。
    static func syncRecent(token: String) async throws -> RecentSyncResult {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let days = [startOfToday,
                    calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday]
        var records: [UsageRecord] = []
        var fetchedDays: [Date] = []
        var coverageEnd: Date? = nil
        for (index, day) in days.enumerated() {
            do {
                let fetched = try await fetchWindow(start: day, end: day.addingTimeInterval(86_400),
                                                    token: token)
                records += fetched.map { var record = $0; record.hourly = true; return record }
                fetchedDays.append(day)
                if index == 0 { coverageEnd = Date() }
            } catch UsageSyncError.invalidToken {
                throw UsageSyncError.invalidToken
            } catch {
                // 网络抖动等：跳过当天，保留现有记录与覆盖边界
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return RecentSyncResult(records: records, fetchedDays: fetchedDays, coverageEnd: coverageEnd)
    }

    // MARK: - 单个窗口拉取

    /// 拉取 [start, end) 的用量（amount + cost），合并为 UsageRecord（按 桶×模型×Key 聚合）。
    /// 全零桶直接丢弃：官网会返回 全部模型 × 全部 Key 的完整矩阵（大量零值桶），
    /// 不剔除会撑大存储、拖慢图表、并污染图例与系列列表。
    private static func fetchWindow(start: Date, end: Date, token: String) async throws -> [UsageRecord] {
        async let amountData = request("by_api_key/amount", start: start, end: end, token: token)
        async let costData = request("by_api_key/cost", start: start, end: end, token: token)
        let amounts = try parseAmount(try await amountData)
        let costs = (try? parseCost(try await costData)) ?? [:]

        var byBucket: [String: UsageRecord] = [:]
        for (key, bucket) in amounts {
            var record = byBucket[key] ?? bucket
            if let cost = costs[key] { record.cost += cost }
            byBucket[key] = record
        }
        // 兜底：cost 有值但 amount 全零的桶（理论上不存在），保留以免丢消费金额
        for (key, cost) in costs where byBucket[key] == nil && cost > 0 {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let seconds = Double(parts[0]) else { continue }
            byBucket[key] = UsageRecord(
                day: Date(timeIntervalSince1970: seconds), model: parts[1], apiKeyName: parts[2],
                inputCacheHit: 0, inputCacheMiss: 0, output: 0, requests: 0, cost: cost
            )
        }
        return byBucket.values
            .filter { $0.totalTokens > 0 || $0.requests > 0 || $0.cost > 0 }
            .sorted { $0.day < $1.day }
    }

    /// key = time|model|apiKeyName
    private static func bucketKey(time: Date, model: String, keyName: String) -> String {
        "\(time.timeIntervalSince1970)|\(model)|\(keyName)"
    }

    private static func parseAmount(_ data: Data) throws -> [String: UsageRecord] {
        guard let envelope = try? JSONDecoder().decode(AmountEnvelope.self, from: data),
              let series = envelope.data?.biz_data?.series else {
            throw UsageSyncError.decodingFailed
        }
        var result: [String: UsageRecord] = [:]
        for entry in series {
            let model = entry.model ?? "unknown"
            let keyName = entry.api_key?.name?.isEmpty == false ? entry.api_key!.name! : "未命名 Key"
            let mask = entry.api_key?.sensitive_id
            for bucket in entry.buckets ?? [] {
                guard let time = bucket.time else { continue }
                let date = Date(timeIntervalSince1970: time)
                let key = bucketKey(time: date, model: model, keyName: keyName)
                var record = result[key] ?? UsageRecord(
                    day: date, model: model, apiKeyName: keyName,
                    inputCacheHit: 0, inputCacheMiss: 0, output: 0, requests: 0,
                    apiKeyMask: mask
                )
                record.inputCacheHit += Int64(bucket.usage?.PROMPT_CACHE_HIT_TOKEN ?? 0)
                record.inputCacheMiss += Int64(bucket.usage?.PROMPT_CACHE_MISS_TOKEN ?? 0)
                record.output += Int64(bucket.usage?.RESPONSE_TOKEN ?? 0)
                record.requests += Int64(bucket.usage?.REQUEST ?? 0)
                result[key] = record
            }
        }
        return result
    }

    private static func parseCost(_ data: Data) throws -> [String: Double] {
        guard let envelope = try? JSONDecoder().decode(CostEnvelope.self, from: data),
              let blocks = envelope.data?.biz_data?.data else {
            throw UsageSyncError.decodingFailed
        }
        // 优先 CNY 块，其次首个货币块
        let block = blocks.first { $0.currency == "CNY" } ?? blocks.first
        var result: [String: Double] = [:]
        for entry in block?.series ?? [] {
            let model = entry.model ?? "unknown"
            let keyName = entry.api_key?.name?.isEmpty == false ? entry.api_key!.name! : "未命名 Key"
            for bucket in entry.buckets ?? [] {
                guard let time = bucket.time, let costString = bucket.cost,
                      let cost = Double(costString) else { continue }
                let key = bucketKey(
                    time: Date(timeIntervalSince1970: time),
                    model: model, keyName: keyName
                )
                result[key, default: 0] += cost
            }
        }
        return result
    }

    // MARK: - HTTP

    private static func request(_ path: String, start: Date, end: Date,
                                token: String) async throws -> Data {
        let tz = TimeZone.current.secondsFromGMT()
        var components = URLComponents(string: "\(base)/api/v0/usage/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(tz)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 官网前端同源接口：带浏览器特征头，避免被 AWS WAF 按默认 UA 拦截
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 || code == 403 { throw UsageSyncError.invalidToken }
        guard code == 200 else { throw UsageSyncError.badResponse(code) }
        // 官网业务错误用 HTTP 200 + body.code ≠ 0（如 40003 invalid token）
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bizCode = obj["code"] as? Int, bizCode != 0 {
            let msg = obj["msg"] as? String ?? ""
            if bizCode == 40003 || msg.contains("Authorization") {
                throw UsageSyncError.invalidToken
            }
            throw UsageSyncError.serverError(bizCode, msg)
        }
        return data
    }
}
