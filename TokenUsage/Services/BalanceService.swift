import Foundation

enum BalanceError: LocalizedError {
    case noAPIKey
    case noEndpoint
    case badURL(String)
    case badResponse(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "未配置 API Key"
        case .noEndpoint: return "未填写查询接口地址"
        case .badURL(let raw): return "接口地址无效：\(raw)"
        case .badResponse(let code): return "请求失败 (HTTP \(code))，请检查 API Key"
        case .decodingFailed: return "无法解析接口返回"
        }
    }
}

/// 一次取数的结果：余额快照（余额制）或额度快照（配额制）
enum FetchResult: Sendable {
    case balance(BalanceSnapshot)
    case quota(ProviderQuota)
}

/// 调用各平台官方接口，返回标准化快照。
struct BalanceService {
    /// 统一取数入口：按服务商路由到对应接口。
    /// endpoint 仅 mimo / custom 使用（账户上填写的自定义查询地址）。
    func fetch(for provider: AIProvider, apiKey: String, endpoint: String? = nil) async throws -> FetchResult {
        guard !apiKey.isEmpty else { throw BalanceError.noAPIKey }
        switch provider {
        case .deepseek, .kimi:
            return .balance(try await fetchBalance(for: provider, apiKey: apiKey))
        case .kimiCode:
            return .quota(try await fetchKimiCodeQuota(apiKey: apiKey))
        case .glm:
            return .quota(try await fetchGLMQuota(apiKey: apiKey))
        case .minimax:
            return .quota(try await fetchMiniMaxQuota(apiKey: apiKey))
        case .claude:
            return .quota(try await fetchClaudeQuota(token: apiKey))
        case .codex:
            return .quota(try await fetchCodexQuota(token: apiKey))
        case .mimo, .custom:
            return try await fetchGeneric(endpoint: endpoint, apiKey: apiKey)
        }
    }

    /// 余额制（DeepSeek / Kimi）：GET 官方余额接口
    private func fetchBalance(for provider: AIProvider, apiKey: String) async throws -> BalanceSnapshot {
        guard let url = provider.balanceEndpoint else { throw BalanceError.decodingFailed }
        let data = try await get(url, headers: ["Authorization": "Bearer \(apiKey)"])
        switch provider {
        case .deepseek:
            return try Self.parseDeepSeek(data)
        case .kimi:
            return try Self.parseKimi(data)
        default:
            throw BalanceError.decodingFailed
        }
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            throw BalanceError.badResponse(statusCode)
        }
        return data
    }

    // MARK: - Kimi Code

    /// Kimi Code: GET /coding/v1/usages（会员配额：周额度 + 滚动窗口 + 并行数）
    func fetchKimiCodeQuota(apiKey: String) async throws -> ProviderQuota {
        let data = try await get(AIProvider.kimiCode.quotaEndpoint!,
                                 headers: ["Authorization": "Bearer \(apiKey)"])
        return try Self.parseKimiCodeQuota(data)
    }

    // 实测响应（2026-08）：usage 为周额度，limits[0] 为 5 小时滚动窗口，
    // 数值字段均为字符串；resetTime 是带毫秒的 ISO8601；
    // boosterWallet = Extra Usage 加量包（status STATUS_ENABLED/DISABLED）
    static func parseKimiCodeQuota(_ data: Data) throws -> ProviderQuota {
        struct Response: Codable {
            struct User: Codable {
                struct Membership: Codable { let level: String? }
                let membership: Membership?
            }
            struct Quota: Codable {
                let limit: String?
                let used: String?
                let resetTime: String?
            }
            struct WindowLimit: Codable {
                struct Window: Codable { let duration: Int? }
                let window: Window?
                let detail: Quota?
            }
            /// parallel.limit 实测既可能是字符串也可能是数字
            struct FlexibleInt: Codable {
                let value: Int
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let int = try? container.decode(Int.self) {
                        value = int
                    } else {
                        value = Int(try container.decode(String.self)) ?? 0
                    }
                }
            }
            struct Parallel: Codable { let limit: FlexibleInt? }
            struct Booster: Codable {
                struct Money: Codable { let priceInCents: String? }
                let status: String?
                let monthlyUsed: Money?
            }
            let user: User?
            let usage: Quota?
            let limits: [WindowLimit]?
            let parallel: Parallel?
            let boosterWallet: Booster?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BalanceError.decodingFailed
        }
        let window = decoded.limits?.first
        return ProviderQuota(
            timestamp: Date(),
            membershipLevel: decoded.user?.membership?.level ?? "",
            weeklyLimit: Int(decoded.usage?.limit ?? "") ?? 0,
            weeklyUsed: Int(decoded.usage?.used ?? "") ?? 0,
            weeklyReset: Self.parseResetTime(decoded.usage?.resetTime),
            windowMinutes: window?.window?.duration ?? 300,
            windowLimit: Int(window?.detail?.limit ?? "") ?? 0,
            windowUsed: Int(window?.detail?.used ?? "") ?? 0,
            windowReset: Self.parseResetTime(window?.detail?.resetTime),
            parallelLimit: decoded.parallel?.limit?.value ?? 0,
            boosterEnabled: decoded.boosterWallet?.status == "STATUS_ENABLED",
            monthlyUsedCents: Int(decoded.boosterWallet?.monthlyUsed?.priceInCents ?? "") ?? 0
        )
    }

    // MARK: - GLM（智谱 Coding Plan）

    /// GLM: GET /api/monitor/usage/quota/limit（平台订阅页自用接口，社区实测可用）。
    /// percentage 为已用百分比；nextResetTime 为毫秒时间戳。
    /// 响应：{ "code": 200, "data": { "limits": [ { "type": "TIME_LIMIT", ... },
    ///   { "type": "TOKENS_LIMIT", ... } ], "level": "..." } }
    private func fetchGLMQuota(apiKey: String) async throws -> ProviderQuota {
        // 智谱该接口按裸 key 鉴权（cc-switch 等工具的实测配置），不接受 Bearer 前缀
        let data = try await get(AIProvider.glm.quotaEndpoint!, headers: [
            "Authorization": apiKey,
            "Accept-Language": "zh-CN,zh",
            "Content-Type": "application/json",
        ])
        return try Self.parseGLMQuota(data)
    }

    static func parseGLMQuota(_ data: Data) throws -> ProviderQuota {
        struct Response: Codable {
            struct Payload: Codable {
                struct Limit: Codable {
                    let type: String?
                    let percentage: Double?
                    let nextResetTime: Double?
                }
                let limits: [Limit]?
                let level: String?
            }
            let code: Int?
            let data: Payload?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let payload = decoded.data else {
            throw BalanceError.decodingFailed
        }
        let timeLimit = payload.limits?.first { $0.type == "TIME_LIMIT" }
        let tokensLimit = payload.limits?.first { $0.type == "TOKENS_LIMIT" }
        guard timeLimit != nil || tokensLimit != nil else { throw BalanceError.decodingFailed }
        return ProviderQuota(
            timestamp: Date(),
            membershipLevel: "",
            weeklyLimit: 0,
            weeklyUsed: 0,
            weeklyReset: millisDate(tokensLimit?.nextResetTime),
            windowMinutes: 300,
            windowLimit: 0,
            windowUsed: 0,
            windowReset: millisDate(timeLimit?.nextResetTime),
            parallelLimit: 0,
            boosterEnabled: false,
            monthlyUsedCents: 0,
            weeklyUsedPercent: tokensLimit?.percentage,
            windowUsedPercent: timeLimit?.percentage,
            planName: payload.level?.isEmpty == false ? payload.level : nil
        )
    }

    // MARK: - MiniMax（Coding Plan / Token Plan）

    /// MiniMax: GET /v1/api/openplatform/coding_plan/remains（失败时回退 /v1/token_plan/remains）。
    /// 响应 model_remains 数组，取 model_name == "general"（无则首条）；
    /// 百分比字段是「剩余」口径，存入时换算为已用。
    private func fetchMiniMaxQuota(apiKey: String) async throws -> ProviderQuota {
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
        ]
        let primary = AIProvider.minimax.quotaEndpoint!
        let data: Data
        do {
            data = try await get(primary, headers: headers)
        } catch {
            // 旧版 Token Plan 端点兜底
            data = try await get(
                URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!,
                headers: headers
            )
        }
        return try Self.parseMiniMaxQuota(data)
    }

    static func parseMiniMaxQuota(_ data: Data) throws -> ProviderQuota {
        struct Response: Codable {
            struct Remains: Codable {
                let model_name: String?
                let current_interval_remaining_percent: Double?
                let current_weekly_remaining_percent: Double?
                let end_time: Double?       // 当前窗口结束（毫秒）
                let remains_time: Double?   // 订阅周期剩余秒数
            }
            let model_remains: [Remains]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let entries = decoded.model_remains, !entries.isEmpty else {
            throw BalanceError.decodingFailed
        }
        let entry = entries.first { $0.model_name == "general" } ?? entries[0]
        let weeklyReset = entry.remains_time.map { Date().addingTimeInterval($0) }
        return ProviderQuota(
            timestamp: Date(),
            membershipLevel: "",
            weeklyLimit: 0,
            weeklyUsed: 0,
            weeklyReset: weeklyReset,
            windowMinutes: 300,
            windowLimit: 0,
            windowUsed: 0,
            windowReset: millisDate(entry.end_time),
            parallelLimit: 0,
            boosterEnabled: false,
            monthlyUsedCents: 0,
            weeklyUsedPercent: entry.current_weekly_remaining_percent.map { 100 - $0 },
            windowUsedPercent: entry.current_interval_remaining_percent.map { 100 - $0 },
            planName: "MiniMax \(entry.model_name ?? "")".trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: - Claude（订阅用量，OAuth 凭证）

    /// Claude: GET /api/oauth/usage（社区发现的 Claude Code 自用接口）。
    /// 凭证为用户本机 Claude Code 登录后的 OAuth accessToken；
    /// User-Agent 必须伪装成 claude-code，否则会被严格限流。
    /// 响应：{ "five_hour": { "utilization": 21.0, "resets_at": "..." },
    ///   "seven_day": { "utilization": 5.0, "resets_at": "..." } }（utilization 为已用百分比）
    private func fetchClaudeQuota(token: String) async throws -> ProviderQuota {
        let data = try await get(AIProvider.claude.quotaEndpoint!, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.0.0",
            "Content-Type": "application/json",
        ])
        return try Self.parseClaudeQuota(data)
    }

    static func parseClaudeQuota(_ data: Data) throws -> ProviderQuota {
        struct Response: Codable {
            struct Window: Codable {
                let utilization: Double?
                let resets_at: String?
            }
            let five_hour: Window?
            let seven_day: Window?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.five_hour != nil || decoded.seven_day != nil else {
            throw BalanceError.decodingFailed
        }
        return ProviderQuota(
            timestamp: Date(),
            membershipLevel: "",
            weeklyLimit: 0,
            weeklyUsed: 0,
            weeklyReset: parseResetTime(decoded.seven_day?.resets_at),
            windowMinutes: 300,
            windowLimit: 0,
            windowUsed: 0,
            windowReset: parseResetTime(decoded.five_hour?.resets_at),
            parallelLimit: 0,
            boosterEnabled: false,
            monthlyUsedCents: 0,
            weeklyUsedPercent: decoded.seven_day?.utilization,
            windowUsedPercent: decoded.five_hour?.utilization,
            planName: nil
        )
    }

    // MARK: - Codex（OpenAI 订阅用量，OAuth 凭证）

    /// Codex: GET https://chatgpt.com/backend-api/wham/usage。
    /// 凭证为 ~/.codex/auth.json 中的 access_token。
    /// 响应：{ "plan_type": "pro", "rate_limit": { "primary_window": { "used_percent": 12,
    ///   "reset_at": 1774000000, "limit_window_seconds": 18000 }, "secondary_window": { ... } } }
    private func fetchCodexQuota(token: String) async throws -> ProviderQuota {
        let data = try await get(AIProvider.codex.quotaEndpoint!, headers: [
            "Authorization": "Bearer \(token)",
            "User-Agent": "codex_cli_rs/1.0",
            "Content-Type": "application/json",
        ])
        return try Self.parseCodexQuota(data)
    }

    static func parseCodexQuota(_ data: Data) throws -> ProviderQuota {
        struct Response: Codable {
            struct RateLimit: Codable {
                struct Window: Codable {
                    let used_percent: Double?
                    let reset_at: Double?
                    let limit_window_seconds: Double?
                }
                let primary_window: Window?
                let secondary_window: Window?
            }
            let plan_type: String?
            let rate_limit: RateLimit?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let rateLimit = decoded.rate_limit else {
            throw BalanceError.decodingFailed
        }
        let primary = rateLimit.primary_window
        let secondary = rateLimit.secondary_window
        return ProviderQuota(
            timestamp: Date(),
            membershipLevel: "",
            weeklyLimit: 0,
            weeklyUsed: 0,
            weeklyReset: secondary?.reset_at.map { Date(timeIntervalSince1970: $0) },
            windowMinutes: Int((primary?.limit_window_seconds ?? 18_000) / 60),
            windowLimit: 0,
            windowUsed: 0,
            windowReset: primary?.reset_at.map { Date(timeIntervalSince1970: $0) },
            parallelLimit: 0,
            boosterEnabled: false,
            monthlyUsedCents: 0,
            weeklyUsedPercent: secondary?.used_percent,
            windowUsedPercent: primary?.used_percent,
            planName: decoded.plan_type?.capitalized
        )
    }

    // MARK: - 自定义接口（小米 MiMo / 自定义模型）

    /// 通用解析：GET 用户填写的地址（Bearer 鉴权），在返回 JSON 中广度优先搜索常见字段。
    /// 先找余额字段（total_balance / available_balance / balance / credits 等），
    /// 找不到再找百分比字段（utilization / used_percent / percentage 等），都没有则报解析失败。
    private func fetchGeneric(endpoint: String?, apiKey: String) async throws -> FetchResult {
        guard let endpoint,
              !endpoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BalanceError.noEndpoint
        }
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw BalanceError.badURL(trimmed)
        }
        let data = try await get(url, headers: [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json",
        ])
        return try Self.parseGeneric(data)
    }

    /// 通用 JSON 解析：广度优先搜索常见余额字段，找不到再找百分比字段
    static func parseGeneric(_ data: Data) throws -> FetchResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw BalanceError.decodingFailed
        }
        if let balance = searchNumeric(in: root, keys: balanceKeys) {
            let currency = searchString(in: root, keys: ["currency"]) ?? "CNY"
            return .balance(BalanceSnapshot(
                timestamp: Date(),
                totalBalance: balance,
                grantedBalance: 0,
                toppedUpBalance: balance,
                currency: currency,
                isAvailable: true
            ))
        }
        if let percent = searchNumeric(in: root, keys: percentKeys) {
            let used = percent > 1 ? percent : percent * 100 // 兼容 0-1 小数与 0-100 百分数
            return .quota(ProviderQuota(
                timestamp: Date(),
                membershipLevel: "",
                weeklyLimit: 0,
                weeklyUsed: 0,
                weeklyReset: nil,
                windowMinutes: 300,
                windowLimit: 0,
                windowUsed: 0,
                windowReset: nil,
                parallelLimit: 0,
                boosterEnabled: false,
                monthlyUsedCents: 0,
                weeklyUsedPercent: min(max(used, 0), 100),
                windowUsedPercent: nil,
                planName: nil
            ))
        }
        throw BalanceError.decodingFailed
    }

    /// 余额字段识别表（按优先级；广度优先先浅层后深层）
    private static let balanceKeys = [
        "total_balance", "totalBalance", "available_balance", "availableBalance",
        "cash_balance", "balance", "remaining_balance", "remainingBalance",
        "remain_balance", "credits", "credit", "remain", "remains", "remaining",
    ]

    /// 百分比字段识别表（已用口径）
    private static let percentKeys = [
        "utilization", "used_percent", "usedPercent", "usage_percent", "usagePercent",
        "percentage", "used_ratio", "usedRatio",
    ]

    /// 广度优先搜索第一个匹配 key 的数值（String / NSNumber 均可）
    private static func searchNumeric(in root: Any, keys: [String], maxDepth: Int = 6) -> Double? {
        var queue: [(value: Any, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (value, depth) = queue[index]
            index += 1
            guard depth < maxDepth else { continue }
            if let dict = value as? [String: Any] {
                for key in keys {
                    if let number = dict[key] as? NSNumber {
                        return number.doubleValue
                    }
                    if let string = dict[key] as? String, let double = Double(string) {
                        return double
                    }
                }
                for child in dict.values { queue.append((child, depth + 1)) }
            } else if let array = value as? [Any] {
                for child in array { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    private static func searchString(in root: Any, keys: [String], maxDepth: Int = 6) -> String? {
        var queue: [(value: Any, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (value, depth) = queue[index]
            index += 1
            guard depth < maxDepth else { continue }
            if let dict = value as? [String: Any] {
                for key in keys {
                    if let string = dict[key] as? String, !string.isEmpty {
                        return string
                    }
                }
                for child in dict.values { queue.append((child, depth + 1)) }
            } else if let array = value as? [Any] {
                for child in array { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    // MARK: - 解析辅助

    private static func parseResetTime(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withMillis = ISO8601DateFormatter()
        withMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withMillis.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// 毫秒时间戳转 Date
    private static func millisDate(_ millis: Double?) -> Date? {
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    // MARK: - 余额制解析

    // DeepSeek: GET /user/balance
    // { "is_available": true, "balance_infos": [ { "currency": "CNY",
    //   "total_balance": "100.00", "granted_balance": "10.00", "topped_up_balance": "90.00" } ] }
    private static func parseDeepSeek(_ data: Data) throws -> BalanceSnapshot {
        struct Response: Codable {
            let is_available: Bool
            let balance_infos: [Info]
            struct Info: Codable {
                let currency: String
                let total_balance: String
                let granted_balance: String
                let topped_up_balance: String
            }
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let info = decoded.balance_infos.first else {
            throw BalanceError.decodingFailed
        }
        return BalanceSnapshot(
            timestamp: Date(),
            totalBalance: Double(info.total_balance) ?? 0,
            grantedBalance: Double(info.granted_balance) ?? 0,
            toppedUpBalance: Double(info.topped_up_balance) ?? 0,
            currency: info.currency,
            isAvailable: decoded.is_available
        )
    }

    // Moonshot: GET /v1/users/me/balance
    // { "code": 0, "status": true, "data": { "available_balance": 49.94,
    //   "voucher_balance": 10.0, "cash_balance": 39.94 } }
    private static func parseKimi(_ data: Data) throws -> BalanceSnapshot {
        struct Response: Codable {
            let code: Int?
            let status: Bool?
            let data: Payload?
            struct Payload: Codable {
                let available_balance: Double?
                let voucher_balance: Double?
                let cash_balance: Double?
            }
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let payload = decoded.data else {
            throw BalanceError.decodingFailed
        }
        let total = payload.available_balance ?? 0
        return BalanceSnapshot(
            timestamp: Date(),
            totalBalance: total,
            grantedBalance: payload.voucher_balance ?? 0,
            toppedUpBalance: payload.cash_balance ?? 0,
            currency: "CNY",
            isAvailable: total > 0
        )
    }
}
