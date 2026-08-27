import Foundation
import SwiftUI
import WidgetKit

/// 全局状态：管理每个服务商的多个 API Key、各 Key 的余额历史、
/// 定时刷新、落盘并通知小组件。
@MainActor
final class BalanceStore: ObservableObject {
    @Published private(set) var keys: [ProviderKey] = []
    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var dataByKey: [UUID: ProviderData] = [:]
    @Published private(set) var usageRecords: [UsageRecord] = []
    @Published private(set) var quotaByKey: [UUID: ProviderQuota] = [:]
    /// GLM 按量计费账号的账单信息（控制台财务接口的官方值，随余额刷新节流同步）
    @Published private(set) var glmBillingByKey: [UUID: GLMBillingInfo] = [:]
    /// 各账户导入数据的精确覆盖截止时间（导入文件中的最大行时间戳）
    @Published private(set) var usageCoverageEnd: [UUID: Date] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var importError: String?

    private let service = BalanceService()
    private var timer: Timer?

    private static let keysDefaultsKey = "providerKeys"
    private static let accountsDefaultsKey = "providerAccounts"
    private static let providerOrderKey = "providerOrder"

    /// 自动刷新间隔（秒），默认 5 分钟
    var refreshInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "refreshInterval")
            return value > 0 ? value : 300
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "refreshInterval")
            scheduleTimer()
        }
    }

    init() {
        loadAccounts()
        loadKeys()
        loadProviderOrder()
        migrateLegacyKeysIfNeeded()
        ensureDefaultAccounts()
        reconcileKeysWithAccounts()
        loadCache()
        scheduleTimer()
        Task { await refresh() }
        // 自动检查更新：延迟 5 秒，避开启动时的数据加载网络高峰（默认开，可在设置关闭）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await UpdateService.shared.checkIfNeeded()
        }
        // 首次安装（无任何 Key 且未走过引导）时弹出初始化向导。
        // BalanceStore 在 App 启动构建场景时必然创建，是可靠的启动钩子；
        // 延迟约 1 秒等窗口环境就绪；TU_HEADLESS 供离屏渲染工具跳过弹窗。
        if keys.isEmpty,
           !UserDefaults.standard.bool(forKey: "onboardingDone"),
           ProcessInfo.processInfo.environment["TU_HEADLESS"] == nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                OnboardingWindowController.shared.showIfNeeded(store: self)
            }
        }
    }

    // MARK: - 服务商展示排序

    /// 面板中服务商卡片的展示顺序（含未配置 Key 的服务商，新增服务商自动排到末尾）
    @Published private(set) var providerOrder: [AIProvider] = AIProvider.allCases

    private func loadProviderOrder() {
        guard let raws = UserDefaults.standard.stringArray(forKey: Self.providerOrderKey) else { return }
        let known = raws.compactMap { AIProvider(rawValue: $0) }
        providerOrder = known + AIProvider.allCases.filter { !known.contains($0) }
    }

    private func saveProviderOrder() {
        UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: Self.providerOrderKey)
    }

    func moveProvider(_ provider: AIProvider, up: Bool) {
        guard let index = providerOrder.firstIndex(of: provider) else { return }
        let target = up ? index - 1 : index + 1
        guard providerOrder.indices.contains(target) else { return }
        providerOrder.swapAt(index, target)
        saveProviderOrder()
    }

    // MARK: - 账户管理

    func accounts(for provider: AIProvider) -> [ProviderAccount] {
        accounts.filter { $0.provider == provider }
    }

    func keys(for account: ProviderAccount) -> [ProviderKey] {
        keys.filter { $0.accountID == account.id }
    }

    /// 某账户的合计余额 = 其下各 Key 最新余额之和
    func totalBalance(for account: ProviderAccount) -> Double {
        keys(for: account).compactMap { dataByKey[$0.id]?.latest?.totalBalance }.reduce(0, +)
    }

    @discardableResult
    func addAccount(provider: AIProvider, name: String) -> ProviderAccount {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let account = ProviderAccount(
            id: UUID(),
            provider: provider,
            name: trimmed.isEmpty ? "账户 \(accounts(for: provider).count + 1)" : trimmed
        )
        accounts.append(account)
        saveAccounts()
        return account
    }

    func renameAccount(_ account: ProviderAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].name = trimmed
        saveAccounts()
    }

    /// 更新账户的自定义查询接口地址（仅 mimo / custom 服务商使用）
    func updateAccountEndpoint(_ account: ProviderAccount, endpoint: String) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].endpoint = trimmed.isEmpty ? nil : trimmed
        saveAccounts()
    }

    /// 更新账户的累计消费校准基数（元；nil / 0 = 未校准）
    func updateAccountCumulativeBase(_ account: ProviderAccount, base: Double?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let value = base ?? 0
        accounts[index].cumulativeBase = value == 0 ? nil : value
        saveAccounts()
    }

    /// 删除账户：连同其下所有 API Key、余额/额度历史与已导入的用量数据
    func removeAccount(_ account: ProviderAccount) {
        for key in keys(for: account) {
            APIKeyStore.save(key: "", for: key.keychainAccount)
            dataByKey.removeValue(forKey: key.id)
            quotaByKey.removeValue(forKey: key.id)
        }
        APIKeyStore.saveSyncToken(nil, for: account.id)
        keys.removeAll { $0.accountID == account.id }
        usageRecords.removeAll { $0.accountID == account.id }
        usageCoverageEnd.removeValue(forKey: account.id)
        accounts.removeAll { $0.id == account.id }
        saveKeys()
        saveAccounts()
        saveCache()
    }

    /// 指定服务商的默认（首个）账户，没有则创建
    private func defaultAccount(for provider: AIProvider) -> ProviderAccount {
        if let existing = accounts(for: provider).first { return existing }
        return addAccount(provider: provider, name: "默认账户")
    }

    /// 每个服务商保底一个账户，设置页与看板都以此为基础
    private func ensureDefaultAccounts() {
        for provider in AIProvider.allCases where accounts(for: provider).isEmpty {
            accounts.append(ProviderAccount(id: UUID(), provider: provider, name: "默认账户"))
        }
        saveAccounts()
    }

    /// 把账户引用失效的 Key（含旧版数据）归并到对应服务商的默认账户
    private func reconcileKeysWithAccounts() {
        var changed = false
        for provider in AIProvider.allCases {
            let validIDs = Set(accounts(for: provider).map(\.id))
            guard let fallback = accounts(for: provider).first else { continue }
            for index in keys.indices
            where keys[index].provider == provider && !validIDs.contains(keys[index].accountID) {
                keys[index].accountID = fallback.id
                changed = true
            }
        }
        if changed { saveKeys() }
    }

    // MARK: - Key 管理

    func keys(for provider: AIProvider) -> [ProviderKey] {
        keys.filter { $0.provider == provider }
    }

    func apiKey(for key: ProviderKey) -> String {
        APIKeyStore.read(for: key.keychainAccount) ?? ""
    }

    func maskedAPIKey(for key: ProviderKey) -> String {
        let value = apiKey(for: key)
        guard value.count > 4 else { return value.isEmpty ? "未设置" : "••••" }
        return "••••" + value.suffix(4)
    }

    /// 添加 Key 到指定账户；accountID 为空或失效时落到默认账户
    func addKey(provider: AIProvider, accountID: UUID?, label: String, apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let account = accounts.first(where: { $0.id == accountID }) ?? defaultAccount(for: provider)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let key = ProviderKey(
            id: UUID(),
            provider: provider,
            label: trimmedLabel.isEmpty ? "Key \(keys(for: account).count + 1)" : trimmedLabel,
            accountID: account.id
        )
        keys.append(key)
        saveKeys()
        APIKeyStore.save(key: trimmedKey, for: key.keychainAccount)
        Task { await refresh() }
    }

    func removeKey(_ key: ProviderKey) {
        APIKeyStore.save(key: "", for: key.keychainAccount)
        keys.removeAll { $0.id == key.id }
        dataByKey.removeValue(forKey: key.id)
        quotaByKey.removeValue(forKey: key.id)
        glmBillingByKey.removeValue(forKey: key.id)
        saveKeys()
        saveCache()
    }

    private func loadKeys() {
        guard let data = UserDefaults.standard.data(forKey: Self.keysDefaultsKey),
              let decoded = try? JSONDecoder().decode([ProviderKey].self, from: data) else {
            return
        }
        keys = decoded
    }

    private func saveKeys() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.keysDefaultsKey)
        }
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsDefaultsKey),
              let decoded = try? JSONDecoder().decode([ProviderAccount].self, from: data) else {
            return
        }
        accounts = decoded
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsDefaultsKey)
        }
    }

    /// 旧版单 Key（≤1.0 存在 Keychain，账户名为 provider rawValue）迁移为多 Key 结构。
    /// 一次性执行：无论是否迁移成功都删除 Keychain 旧条目，
    /// 避免用户删光所有 Key 后旧 Key 被反复"复活"成默认 Key
    private func migrateLegacyKeysIfNeeded() {
        let doneKey = "legacyKeyMigrationDone"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)

        let legacy = AIProvider.allCases.compactMap { provider -> (AIProvider, String)? in
            guard let value = LegacyKeychainReader.read(account: provider.rawValue), !value.isEmpty else { return nil }
            return (provider, value)
        }
        // 只有完全没配置过 Key 时才恢复旧 Key；已有配置则只清理残留
        if keys.isEmpty {
            for (provider, value) in legacy {
                let key = ProviderKey(
                    id: UUID(),
                    provider: provider,
                    label: "默认 Key",
                    accountID: defaultAccount(for: provider).id
                )
                keys.append(key)
                APIKeyStore.save(key: value, for: key.keychainAccount)
            }
            if !legacy.isEmpty { saveKeys() }
        }
        for (provider, _) in legacy {
            LegacyKeychainReader.delete(account: provider.rawValue)
        }
    }

    // MARK: - 用量导入（DeepSeek 平台导出 ZIP）

    /// 导入某账户的用量导出 ZIP。同账户重复导入视为校准：先清该账户旧数据再写入。
    /// 注意必须写回盖过账户标记的记录副本——直接 append 解析结果会丢失 accountID，
    /// 导致看板按账户过滤时整条数据不可见（重启后才被归并迁移救回，且账户归错）。
    func importUsage(from url: URL, into account: ProviderAccount) {
        do {
            let result = try UsageImporter.importZIP(at: url)
            var stamped = result.records
            for index in stamped.indices { stamped[index].accountID = account.id }
            usageRecords.removeAll { $0.accountID == account.id }
            usageRecords.append(contentsOf: stamped)
            usageRecords.sort { $0.day < $1.day }
            usageCoverageEnd[account.id] = result.coverageEnd
            importError = nil
            saveCache()
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - 官网同步（DeepSeek）

    func syncToken(for account: ProviderAccount) -> String? {
        APIKeyStore.readSyncToken(for: account.id)
    }

    func saveSyncToken(_ token: String, for account: ProviderAccount) {
        APIKeyStore.saveSyncToken(token, for: account.id)
        // 重新登录后解除自动同步封锁并立刻补一次今天/昨天的逐小时同步
        recentSyncBlocked.remove(account.id)
        lastRecentSync.removeValue(forKey: account.id)
        Task { await refresh() }
    }

    func clearSyncToken(for account: ProviderAccount) {
        APIKeyStore.saveSyncToken(nil, for: account.id)
        lastRecentSync.removeValue(forKey: account.id)
    }

    /// 官网同步结果入库：替换该账户全部用量记录，覆盖边界为同步时刻
    func applySyncedUsage(_ result: UsageSyncService.SyncResult, into account: ProviderAccount) {
        var stamped = result.records
        for index in stamped.indices { stamped[index].accountID = account.id }
        usageRecords.removeAll { $0.accountID == account.id }
        usageRecords.append(contentsOf: stamped)
        usageRecords.sort { $0.day < $1.day }
        usageCoverageEnd[account.id] = result.coverageEnd
        importError = nil
        saveCache()
    }

    // MARK: - 定时轻量同步（DeepSeek 今天/昨天逐小时）

    /// 自动轻量同步的最小间隔：官网接口有频率限制，不能随每次余额刷新都跑
    private static let recentSyncMinInterval: TimeInterval = 600
    private var lastRecentSync: [UUID: Date] = [:]
    /// 登录态失效的账户：本次运行期内停止自动同步（重新登录保存 token 后解除）
    private var recentSyncBlocked: Set<UUID> = []

    /// 用已保存的官网登录态轻量同步「今天 + 昨天」的逐小时用量。
    /// 没有它，今天/昨天维度的消耗只能按历史模型占比估算——账户切换模型后
    /// 会把新消耗摊给不再使用的旧模型（今天视图冒出没用过的模型的根因）。
    private func autoSyncRecentUsage() async {
        for account in accounts where account.provider == .deepseek {
            guard !recentSyncBlocked.contains(account.id),
                  let token = syncToken(for: account), !token.isEmpty,
                  Date().timeIntervalSince(lastRecentSync[account.id] ?? .distantPast)
                      >= Self.recentSyncMinInterval
            else { continue }
            lastRecentSync[account.id] = Date()
            do {
                let result = try await UsageSyncService.syncRecent(token: token)
                applyRecentSyncedUsage(result, into: account)
            } catch UsageSyncError.invalidToken {
                recentSyncBlocked.insert(account.id)
            } catch {
                // 网络失败等：下一轮定时器再试
            }
        }
    }

    /// 轻量同步结果入库：只替换成功拉取的那几天（保留更早的导入/同步历史）；
    /// 今天拉取成功才把覆盖边界推进到同步时刻（其后的消耗仍由余额差额实时估算）。
    func applyRecentSyncedUsage(_ result: UsageSyncService.RecentSyncResult,
                                into account: ProviderAccount) {
        guard !result.fetchedDays.isEmpty else { return }
        let fetched = Set(result.fetchedDays.map { Calendar.current.startOfDay(for: $0) })
        var stamped = result.records
        for index in stamped.indices { stamped[index].accountID = account.id }
        usageRecords.removeAll {
            $0.accountID == account.id
                && fetched.contains(Calendar.current.startOfDay(for: $0.day))
        }
        usageRecords.append(contentsOf: stamped)
        usageRecords.sort { $0.day < $1.day }
        if let end = result.coverageEnd, end > (usageCoverageEnd[account.id] ?? .distantPast) {
            usageCoverageEnd[account.id] = end
        }
        saveCache()
    }

    /// 清除所有数据并恢复到首次安装状态：删除所有 API Key（含本地密钥文件）、
    /// 账户、余额历史、额度与已导入的用量数据，连同面板高度、筛选、排序等
    /// 本地偏好一并重置；随后重建各服务商的空「默认账户」供重新配置。
    func clearAllData() {
        APIKeyStore.removeAll()
        keys = []
        accounts = []
        dataByKey = [:]
        usageRecords = []
        quotaByKey = [:]
        glmBillingByKey = [:]
        usageCoverageEnd = [:]
        lastRefresh = nil
        importError = nil
        providerOrder = AIProvider.allCases
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // removePersistentDomain 会连带清掉 App 级的滚动条偏好，立即补回
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        ensureDefaultAccounts() // 重建空账户；内部会 saveAccounts()
        saveKeys()
        saveCache()
    }

    /// 账户的实时起算边界：导入数据的精确覆盖截止时间，其后的消耗用余额快照差额实时推算。
    /// 旧缓存没有记录覆盖时间时，退化为导入截止日的次日 0 点（重新导入一次即可精确）；
    /// 该账户无导入数据时从头算起。
    func liveStart(forAccountID accountID: UUID) -> Date {
        if let end = usageCoverageEnd[accountID] { return end }
        return usageRecords.filter { $0.accountID == accountID }.map(\.day).max()
            .map { $0.addingTimeInterval(86_400) } ?? .distantPast
    }

    // MARK: - 查询 / 聚合

    func data(for key: ProviderKey) -> ProviderData? {
        dataByKey[key.id]
    }

    /// 某 Key 的配额快照（配额制 / 返回百分比的自定义接口）
    func quota(for key: ProviderKey) -> ProviderQuota? {
        quotaByKey[key.id]
    }

    /// 某 Key 的 GLM 账单信息（仅按量计费的 GLM 账号有）
    func glmBilling(for key: ProviderKey) -> GLMBillingInfo? {
        glmBillingByKey[key.id]
    }

    /// 某服务商下所有 Key 的数据
    func allData(for provider: AIProvider) -> [ProviderData] {
        keys(for: provider).compactMap { dataByKey[$0.id] }
    }

    /// 本地 Key 在导入数据中对应的平台 Key 名：同名优先；
    /// 其次用导入 CSV 的掩码 API Key（sk-abc***xyz）与本地完整 Key 做前后缀比对精确归属；
    /// 账户内本地 Key 与导入 Key 名都唯一时直接对应，否则无法确定归属，返回 nil
    func importedKeyName(for key: ProviderKey) -> String? {
        let accountRecords = usageRecords.filter { $0.accountID == key.accountID }
        let importedNames = Set(accountRecords.map(\.apiKeyName))
        if importedNames.contains(key.label) { return key.label }
        // 掩码匹配：一个平台 Key 名的掩码与本地 Key 前后缀吻合且唯一时，精确归属
        let local = apiKey(for: key)
        if !local.isEmpty {
            var maskByName: [String: String] = [:]
            for record in accountRecords {
                guard let mask = record.apiKeyMask, !mask.isEmpty else { continue }
                maskByName[record.apiKeyName] = mask
            }
            let hits = maskByName.filter { Self.mask($0.value, matches: local) }.map(\.key)
            if hits.count == 1 { return hits[0] }
        }
        let localCount = keys.filter { $0.accountID == key.accountID }.count
        if localCount == 1 && importedNames.count == 1 { return importedNames.first! }
        return nil
    }

    /// 掩码 Key 匹配：sk-abc***xyz → 本地 Key 以前缀 sk-abc 开头、以 xyz 结尾。
    /// 前缀/后缀太短（< 4 字符）时不判，避免误归属。
    private static func mask(_ mask: String, matches apiKey: String) -> Bool {
        guard let starRange = mask.range(of: #"\*+"#, options: .regularExpression) else { return false }
        let prefix = String(mask[mask.startIndex..<starRange.lowerBound])
        let suffix = String(mask[starRange.upperBound...])
        guard prefix.count >= 4 || suffix.count >= 4 else { return false }
        return apiKey.hasPrefix(prefix) && apiKey.hasSuffix(suffix)
            && apiKey.count > prefix.count + suffix.count
    }

    /// 合计余额 = 各 Key 最新余额之和
    func totalBalance(for provider: AIProvider) -> Double {
        allData(for: provider).compactMap { $0.latest?.totalBalance }.reduce(0, +)
    }

    func currency(for provider: AIProvider) -> String {
        allData(for: provider).compactMap { $0.latest?.currency }.first ?? "CNY"
    }

    /// 合计消耗 = 各 Key 在 [date, until) 内的消耗之和
    func consumption(for provider: AIProvider, since date: Date, until: Date = .distantFuture) -> Double {
        allData(for: provider).map { $0.consumption(since: date, until: until) }.reduce(0, +)
    }

    func hasAnyData(for provider: AIProvider) -> Bool {
        allData(for: provider).contains { $0.latest != nil }
    }

    var totalBalance: Double {
        AIProvider.allCases.map { totalBalance(for: $0) }.reduce(0, +)
    }

    var hasAnyData: Bool {
        AIProvider.allCases.contains { hasAnyData(for: $0) }
    }

    var hasAnyKey: Bool {
        !keys.isEmpty
    }

    // MARK: - 刷新

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for key in keys {
            let apiKey = apiKey(for: key)
            guard !apiKey.isEmpty else { continue }
            var data = dataByKey[key.id] ?? ProviderData()
            let endpoint = accounts.first(where: { $0.id == key.accountID })?.endpoint
            // 小米 MiMo 没有按 Key 的公开余额 API：余额随官网登录同步写回，
            // 未配置通用接口时跳过刷新并清掉历史报错（保留最近一次同步的余额快照）
            if key.provider == .mimo, endpoint?.isEmpty ?? true {
                data.lastError = nil
                dataByKey[key.id] = data
                continue
            }
            do {
                let result = try await service.fetch(for: key.provider, apiKey: apiKey, endpoint: endpoint)
                switch result {
                case .balance(let snapshot):
                    data.snapshots.append(snapshot)
                    data.snapshots = prune(data.snapshots)
                case .quota(let quota):
                    // 配额制：拉额度快照，余额历史不适用
                    quotaByKey[key.id] = quota
                }
                data.lastError = nil
                // GLM 按量计费账号：顺手节流同步账单信息（累计/本月按模型/月度历史）
                if key.provider == .glm, case .balance = result {
                    await syncGLMBillingIfNeeded(for: key, apiKey: apiKey)
                }
            } catch {
                data.lastError = error.localizedDescription
            }
            dataByKey[key.id] = data
        }

        lastRefresh = Date()
        saveCache()
        // 有官网登录态的 DeepSeek 账户：轻量同步今天/昨天的逐小时用量（内部有节流），
        // 让今天/昨天维度的模型归属是官网精确值而非余额差额的占比估算
        await autoSyncRecentUsage()
    }

    /// 保留最近 90 天，且最多 5000 条，防止缓存无限增长
    private func prune(_ snapshots: [BalanceSnapshot]) -> [BalanceSnapshot] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let recent = snapshots.filter { $0.timestamp > cutoff }
        return Array(recent.suffix(5_000))
    }

    /// 小米 MiMo 官网同步带回的余额：写入该账户所有 Key 的快照并清错，
    /// 让看板「剩余余额」显示最近一次同步的官网值（MiMo 无按 Key 公开余额 API）。
    func applyMimoBalance(_ balance: Double, currency: String, to account: ProviderAccount) {
        let snapshot = BalanceSnapshot(
            timestamp: Date(),
            totalBalance: balance,
            grantedBalance: 0,
            toppedUpBalance: balance,
            currency: currency,
            isAvailable: true
        )
        for key in keys(for: account) {
            var data = dataByKey[key.id] ?? ProviderData()
            data.snapshots.append(snapshot)
            data.snapshots = prune(data.snapshots)
            data.lastError = nil
            dataByKey[key.id] = data
        }
        lastRefresh = Date()
        saveCache()
    }

    /// GLM 账单同步的节流间隔：账单接口按分钟级刷新没意义，30 分钟一次足够
    private static let glmBillingMinInterval: TimeInterval = 1800
    private var lastGLMBillingSync: [UUID: Date] = [:]

    /// GLM 按量计费账号的账单信息同步（累计消费/充值/赠送 + 本月按模型 + 历史按月）。
    /// 接口都接受 API Key 鉴权，无需官网登录态；失败静默（下一轮再说）。
    private func syncGLMBillingIfNeeded(for key: ProviderKey, apiKey: String) async {
        let last = lastGLMBillingSync[key.id] ?? glmBillingByKey[key.id]?.updatedAt ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.glmBillingMinInterval else { return }
        lastGLMBillingSync[key.id] = Date()
        if let info = try? await service.fetchGLMBilling(apiKey: apiKey) {
            glmBillingByKey[key.id] = info
            saveCache()
        }
    }

    // MARK: - 持久化 / 小组件同步

    private func loadCache() {
        if let cache = SharedStore.read() {
            for (idString, data) in cache.dataByKey {
                if let id = UUID(uuidString: idString) {
                    var data = data
                    // 防御性排序：快照的有序性靠这里 + 轮询追加（天然升序）维持，
                    // 读取方法（consumption*）因此不再每次重排
                    data.snapshots.sort { $0.timestamp < $1.timestamp }
                    dataByKey[id] = data
                }
            }
            usageRecords = cache.usageRecords
            for (idString, quota) in cache.quotaByKey {
                if let id = UUID(uuidString: idString) {
                    quotaByKey[id] = quota
                }
            }
            for (idString, billing) in cache.glmBilling {
                if let id = UUID(uuidString: idString) {
                    glmBillingByKey[id] = billing
                }
            }
            for (idString, end) in cache.usageCoverageEnd {
                if let id = UUID(uuidString: idString) {
                    usageCoverageEnd[id] = end
                }
            }
        } else if let legacy = SharedStore.readLegacy() {
            // 旧版缓存一次性迁移：providers[provider] 挂到该服务商第一个 Key 上
            for (raw, data) in legacy.providers {
                guard let provider = AIProvider(rawValue: raw),
                      let key = keys.first(where: { $0.provider == provider }) else { continue }
                dataByKey[key.id] = data
            }
        }
        migrateUsageRecords()
    }

    /// 旧版导入记录没有账户归属，归并到 DeepSeek 默认账户
    private func migrateUsageRecords() {
        guard usageRecords.contains(where: { $0.accountID == nil }) else { return }
        let account = defaultAccount(for: .deepseek)
        for index in usageRecords.indices where usageRecords[index].accountID == nil {
            usageRecords[index].accountID = account.id
        }
        saveCache()
    }

    private func saveCache() {
        var dict: [String: ProviderData] = [:]
        for (id, data) in dataByKey {
            dict[id.uuidString] = data
        }
        var quotaDict: [String: ProviderQuota] = [:]
        for (id, quota) in quotaByKey {
            quotaDict[id.uuidString] = quota
        }
        var cache = SharedCache(
            keys: keys,
            dataByKey: dict,
            usageRecords: usageRecords,
            quotaByKey: quotaDict,
            usageCoverageEnd: Dictionary(
                uniqueKeysWithValues: usageCoverageEnd.map { ($0.key.uuidString, $0.value) }
            ),
            updatedAt: Date()
        )
        cache.glmBilling = Dictionary(
            uniqueKeysWithValues: glmBillingByKey.map { ($0.key.uuidString, $0.value) }
        )
        SharedStore.write(cache)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
}
