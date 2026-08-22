import Foundation
import WebKit

/// 小米 MiMo 开放平台（platform.xiaomimimo.com）控制台用量同步。
///
/// 鉴权：小米账号 SSO 登录后种下的会话 cookie——
///   api-platform_serviceToken（httpOnly，真鉴权）/ api-platform_ph（POST 时拼到 query）/
///   api-platform_slh / userId；均为会话 cookie，失效后接口返回 401 + loginUrl。
///
/// 重要：官网网关（MiFE）对 POST 做客户端指纹校验，curl / URLSession 重放
/// 会被 401（浏览器内 fetch 正常）。因此所有请求都在 WKWebView 页面上下文里
/// 通过 fetch 发出（MimoWebSyncDriver），cookie 注入到驱动的非持久数据仓。
///
/// 端点（均 /api/v1 前缀，与控制台前端一致）：
///   GET  /usage                  总览：costUsage.totalCost（全部累计消费）等
///   GET  /balance                余额：balance / cashBalance / giftBalance
///   GET  /apiKeys?withDeleted=true  Key 列表：apiKeyName ↔ redactedApiKey（掩码）
///   POST /usage/detail/list      API 用量计费明细：{year, month?} → 按天×模型×Key
///   POST /usage/token-plan/list  Token Plan 套餐明细：{year, month?} → 按天×模型（无金额）
enum MimoSyncService {

    typealias Progress = @Sendable (String) -> Void

    /// 登录态（从登录窗口的 WKWebView cookie 中提取），按账户 JSON 序列化存放
    struct Session: Codable, Sendable {
        let serviceToken: String
        let ph: String
        let slh: String?
        let userId: String?
    }

    struct SyncOutput {
        /// 用量记录（API 计费 + Token Plan 套餐两池）
        let records: [UsageRecord]
        let coverageEnd: Date
        /// 注册至今累计消费（官网总览口径，元）；用于自动填充累计消费校准
        let totalCost: Double?
        /// 当前余额（元）
        let balance: Double?
        let currency: String?
    }

    // MARK: - 响应模型

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int?
        let data: T?
    }

    private struct DetailItem: Decodable {
        let date: String?             // "2026-05-27"
        let model: String?
        let apiKey: String?           // 掩码 sk-abc***xyz
        let consumedAmount: String?   // 字符串金额
        let totalToken: Double?
        let inputHitToken: Double?
        let inputMissToken: Double?
        let outputToken: Double?
        let requestCount: Double?
    }

    private struct PlanItem: Decodable {
        let date: String?
        let model: String?
        let totalToken: Double?
        let inputHitToken: Double?
        let inputMissToken: Double?
        let outputToken: Double?
        let requestCount: Double?
    }

    private struct ApiKeyItem: Decodable {
        let apiKeyName: String?
        let redactedApiKey: String?
    }

    private struct UsageOverview: Decodable {
        struct CostUsage: Decodable { let totalCost: String? }
        let costUsage: CostUsage?
    }

    private struct BalanceInfo: Decodable {
        let balance: String?
        let currency: String?
    }

    // MARK: - 同步入口

    /// 从所选月份 1 号起逐月拉取 API 计费 + Token Plan 明细直到今天。
    /// 接口按月出按天明细；套餐记录无金额（订阅池），模型名加「·套餐」后缀与计费池区分。
    @MainActor
    static func sync(fromMonth monthStart: Date, session: Session,
                     progress: Progress? = nil) async throws -> SyncOutput {
        let calendar = Calendar.current
        let now = Date()

        // 先起驱动：注入 cookie + 加载同域页面（后续所有请求在页面内发 fetch）
        try await MimoWebSyncDriver.shared.prepare(session: session)

        // Key 掩码 → Key 名映射（计费明细里的 apiKey 是掩码）
        let keyNames = try await fetchKeyNames()

        var all: [UsageRecord] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: monthStart))!
        let endCursor = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        while cursor <= endCursor {
            let year = calendar.component(.year, from: cursor)
            let month = calendar.component(.month, from: cursor)
            progress?(String(format: "%d-%02d", year, month))
            all += try await fetchBillingDetail(year: year, month: month, keyNames: keyNames)
            all += try await fetchPlanDetail(year: year, month: month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            // 控制台接口未标注限流，稳妥起见稍作停顿
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let overview = try? await fetchOverview()
        let balanceInfo = try? await fetchBalance()

        return SyncOutput(
            records: all.sorted { $0.day < $1.day },
            coverageEnd: now,
            totalCost: overview,
            balance: balanceInfo?.0,
            currency: balanceInfo?.1
        )
    }

    // MARK: - 各类拉取

    /// API 用量计费明细（按天 × 模型 × Key），金额字符串转 Double
    @MainActor
    private static func fetchBillingDetail(year: Int, month: Int,
                                           keyNames: [String: String]) async throws -> [UsageRecord] {
        let items: [DetailItem] = try await postList(
            "/usage/detail/list", body: ["year": year, "month": month]
        )
        let formatter = dayFormatter()
        return items.compactMap { item in
            guard let dateString = item.date, let day = formatter.date(from: dateString) else { return nil }
            let tokens = Int64(item.totalToken ?? 0)
            let requests = Int64(item.requestCount ?? 0)
            let cost = Double(item.consumedAmount ?? "") ?? 0
            guard tokens > 0 || requests > 0 || cost > 0 else { return nil }
            let mask = item.apiKey ?? ""
            let keyName = keyNames[mask] ?? (mask.isEmpty ? "未知 Key" : mask)
            return UsageRecord(
                day: day, model: item.model ?? "unknown", apiKeyName: keyName,
                inputCacheHit: Int64(item.inputHitToken ?? 0),
                inputCacheMiss: Int64(item.inputMissToken ?? 0),
                output: Int64(item.outputToken ?? 0),
                requests: requests, cost: cost,
                apiKeyMask: mask.isEmpty ? nil : mask
            )
        }
    }

    /// Token Plan 套餐用量（按天 × 模型，无金额、无 Key 维度）。
    /// 模型名加「·套餐」后缀与计费池区分；Key 维度归到「Token Plan」。
    @MainActor
    private static func fetchPlanDetail(year: Int, month: Int) async throws -> [UsageRecord] {
        let items: [PlanItem] = try await postList(
            "/usage/token-plan/list", body: ["year": year, "month": month]
        )
        let formatter = dayFormatter()
        return items.compactMap { item in
            guard let dateString = item.date, let day = formatter.date(from: dateString) else { return nil }
            let tokens = Int64(item.totalToken ?? 0)
            let requests = Int64(item.requestCount ?? 0)
            guard tokens > 0 || requests > 0 else { return nil }
            return UsageRecord(
                day: day, model: "\(item.model ?? "unknown") · 套餐", apiKeyName: "Token Plan",
                inputCacheHit: Int64(item.inputHitToken ?? 0),
                inputCacheMiss: Int64(item.inputMissToken ?? 0),
                output: Int64(item.outputToken ?? 0),
                requests: requests, cost: 0
            )
        }
    }

    /// Key 掩码 → Key 名
    @MainActor
    private static func fetchKeyNames() async throws -> [String: String] {
        let items: [ApiKeyItem] = try await get("/apiKeys?withDeleted=true")
        var map: [String: String] = [:]
        for item in items {
            guard let mask = item.redactedApiKey, !mask.isEmpty,
                  let name = item.apiKeyName, !name.isEmpty else { continue }
            map[mask] = name
        }
        return map
    }

    /// 累计消费（注册至今，官网总览口径）
    @MainActor
    private static func fetchOverview() async throws -> Double? {
        let overview: UsageOverview = try await get("/usage")
        guard let raw = overview.costUsage?.totalCost else { return nil }
        return Double(raw)
    }

    @MainActor
    private static func fetchBalance() async throws -> (Double, String)? {
        let info: BalanceInfo = try await get("/balance")
        guard let raw = info.balance, let value = Double(raw) else { return nil }
        return (value, info.currency ?? "CNY")
    }

    // MARK: - 请求封装（经 WKWebView 页面上下文）

    @MainActor
    private static func get<T: Decodable>(_ path: String) async throws -> T {
        let text = try await MimoWebSyncDriver.shared.api(path: path, method: "GET", body: nil)
        return try decode(text, as: T.self)
    }

    @MainActor
    private static func postList<T: Decodable>(_ path: String, body: [String: Int]) async throws -> T {
        let text = try await MimoWebSyncDriver.shared.api(path: path, method: "POST", body: body)
        return try decode(text, as: T.self)
    }

    private static func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw UsageSyncError.decodingFailed
        }
        if envelope.code == 401 { throw UsageSyncError.invalidToken }
        if let bizCode = envelope.code, bizCode != 0 {
            throw UsageSyncError.serverError(bizCode, "")
        }
        guard let payload = envelope.data else { throw UsageSyncError.decodingFailed }
        return payload
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }
}

/// MiMo 官网请求驱动：隐藏 WKWebView 加载同域页面，所有 API 在页面 JS 上下文里发 fetch。
/// 官网网关对 POST 做客户端指纹校验，非浏览器客户端（curl/URLSession）会被 401；
/// 页面内 fetch 与控制台前端完全同构，可正常通过。
@MainActor
final class MimoWebSyncDriver {
    static let shared = MimoWebSyncDriver()

    private static let base = "https://platform.xiaomimimo.com"

    private var webView: WKWebView?

    /// 注入会话 cookie 并加载同域页面。每次同步重建非持久数据仓，避免跨账户残留。
    func prepare(session: MimoSyncService.Session) async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let jar = store.httpCookieStore
        var pairs: [(String, String)] = [
            ("api-platform_serviceToken", session.serviceToken),
            ("api-platform_ph", session.ph),
        ]
        if let slh = session.slh { pairs.append(("api-platform_slh", slh)) }
        if let userId = session.userId { pairs.append(("userId", userId)) }
        for (name, value) in pairs {
            guard let cookie = HTTPCookie(properties: [
                .name: name, .value: value,
                .domain: "platform.xiaomimimo.com", .path: "/",
                .secure: "TRUE",
            ]) else { continue }
            await jar.setCookie(cookie)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let wv = WKWebView(frame: .zero, configuration: config)
        webView = wv
        // 公开页即可，只需要同域的 JS 执行上下文
        wv.load(URLRequest(url: URL(string: "\(Self.base)/token-plan")!))
        // 等导航结束（最多 20 秒）
        var waited = 0.0
        while wv.isLoading, waited < 20 {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
    }

    /// 在页面上下文里调 /api/v1 接口，返回响应文本。
    /// ph 参数按前端逻辑从 document.cookie 读出拼到 POST 的 query 上。
    func api(path: String, method: String, body: [String: Int]?) async throws -> String {
        guard let webView else { throw UsageSyncError.notLoggedIn }
        let bodyJS: String
        if let body,
           let data = try? JSONSerialization.data(withJSONObject: body),
           let raw = String(data: data, encoding: .utf8) {
            bodyJS = raw
        } else {
            bodyJS = "null"
        }
        // 返回 {status, text}：opaqueredirect（会话失效被 302 到登录页）按 401 处理。
        // callAsyncJavaScript 直接把字符串当 async 函数体执行，可自由 await/return
        let js = """
        const readCk = (name) => {
          for (const e of document.cookie.split("; ")) {
            if (e.startsWith(name + "=")) {
              return decodeURIComponent(e.slice(name.length + 1)).replace(/^"|"$/g, "").trim();
            }
          }
          return null;
        };
        try {
          let url = "\(Self.base)/api/v1\(path)";
          const method = "\(method)";
          if (method === "POST") {
            const ph = readCk("api-platform_ph") || "";
            url += (url.includes("?") ? "&" : "?") + "api-platform_ph=" + encodeURIComponent(ph);
          }
          const opt = {
            method,
            headers: {
              "Accept-Language": "zh-CN",
              "x-timeZone": Intl.DateTimeFormat().resolvedOptions().timeZone
            },
            credentials: "same-origin",
            redirect: "manual"
          };
          const rawBody = \(bodyJS);
          if (rawBody) {
            opt.headers["Content-Type"] = "application/json";
            opt.body = JSON.stringify(rawBody);
          }
          const r = await fetch(url, opt);
          if (r.type === "opaqueredirect" || r.status === 0) {
            return JSON.stringify({status: 401, text: ""});
          }
          const text = await r.text();
          return JSON.stringify({status: r.status, text: text});
        } catch (e) {
          return JSON.stringify({status: -1, text: String(e && e.message || e)});
        }
        """
        let raw = try await webView.callAsyncJavaScript(
            js, arguments: [:], in: nil, contentWorld: .page
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int else {
            throw UsageSyncError.decodingFailed
        }
        if status == 401 || status == 403 { throw UsageSyncError.invalidToken }
        if status == -1 {
            throw UsageSyncError.serverError(-1, String((obj["text"] as? String ?? "").prefix(100)))
        }
        guard status == 200 else { throw UsageSyncError.badResponse(status) }
        return obj["text"] as? String ?? ""
    }
}
