import SwiftUI

/// 设置窗口：服务商以选项卡切换（避免服务商增多后长时间滚动）；
/// 每个服务商可添加多个账户，账户下可添加/删除多个 API Key；
/// 另设刷新间隔与「清除所有数据」（恢复到首次安装状态）。
struct SettingsView: View {
    @EnvironmentObject private var store: BalanceStore
    @State private var newLabels: [UUID: String] = [:]   // 按账户 ID
    @State private var newKeys: [UUID: String] = [:]
    /// 累计消费校准输入框的原始文本（按账户 ID；实时解析入库，文本本地保留避免输入被打断）
    @State private var baseInputs: [UUID: String] = [:]
    @State private var renamingAccount: ProviderAccount?
    @State private var deletingAccount: ProviderAccount?
    @State private var addAccountAlertProvider: AIProvider?
    @State private var accountNameInput = ""
    @State private var showClearAllConfirm = false
    /// 官网同步：待选月份的账户 / 待登录引导的账户
    @State private var syncAccount: ProviderAccount?
    @State private var loginPromptAccount: ProviderAccount?
    /// 当前选中的服务商选项卡
    @AppStorage("settings.provider") private var selectedProviderRaw: String = AIProvider.deepseek.rawValue
    /// 菜单栏图标旁的显示内容（total = 全部余额合计 / none = 仅图标 / 服务商 rawValue）
    @AppStorage("menuBarSource") private var menuBarSource = "total"
    /// 配额制服务商在菜单栏显示时的口径（weekly = 本周剩余 / window = 5 小时窗口剩余）
    @AppStorage("menuBarQuotaScope") private var menuBarQuotaScope = "weekly"
    // 看板模块显隐（与 ProviderCardView 共用同一组 AppStorage 键）
    @AppStorage("module.balanceCard") private var showBalanceCard = true
    @AppStorage("module.accountCards") private var showAccountCards = true
    @AppStorage("module.keyRows") private var showKeyRows = true
    @AppStorage("module.statCards") private var showStatCards = true
    @AppStorage("module.costChart") private var showCostChart = true
    @AppStorage("module.modelCharts") private var showModelCharts = true
    @AppStorage("module.liveEstimate") private var showLiveEstimate = true

    private var selectedProvider: AIProvider {
        AIProvider(rawValue: selectedProviderRaw) ?? .deepseek
    }

    var body: some View {
        Form {
            Section {
                ProviderTabBar(selection: $selectedProviderRaw)
                    .padding(.vertical, 2)
            }

            Section(selectedProvider.displayName) {
                ForEach(store.accounts(for: selectedProvider)) { account in
                    accountBlock(account, provider: selectedProvider)
                }
                Button {
                    accountNameInput = ""
                    addAccountAlertProvider = selectedProvider
                } label: {
                    Label("添加账户", systemImage: "plus.circle")
                }
                .help("同一平台有多个账号时，为每个账号建一个账户")
                Text(selectedProvider.credentialHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("展示排序") {
                ForEach(store.providerOrder) { provider in
                    HStack {
                        Circle()
                            .fill(provider.accentColor)
                            .frame(width: 8, height: 8)
                        Text(provider.displayName)
                        Spacer()
                        Button {
                            store.moveProvider(provider, up: true)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(provider == store.providerOrder.first)
                        .help("上移")
                        Button {
                            store.moveProvider(provider, up: false)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(provider == store.providerOrder.last)
                        .help("下移")
                    }
                }
                Text("菜单栏面板中的服务商卡片按此顺序展示。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("看板模块") {
                Toggle("合并余额卡（今日消耗 / 剩余余额）", isOn: $showBalanceCard)
                Toggle("各账户卡片", isOn: $showAccountCards)
                Toggle("API Key 列表", isOn: $showKeyRows)
                Toggle("统计卡（消费金额 / 请求次数 / Tokens 明细）", isOn: $showStatCards)
                Toggle("消费金额图表", isOn: $showCostChart)
                Toggle("各模型 Tokens / 请求次数图表", isOn: $showModelCharts)
                Toggle("实时估算图表", isOn: $showLiveEstimate)
                Text("关闭的模块会在菜单栏看板中隐藏，随时可重新打开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("通用") {
                Picker("自动刷新间隔", selection: intervalBinding) {
                    Text("1 分钟").tag(60.0)
                    Text("5 分钟").tag(300.0)
                    Text("15 分钟").tag(900.0)
                    Text("30 分钟").tag(1800.0)
                }
            }

            Section("菜单栏") {
                Picker("图标旁显示", selection: $menuBarSource) {
                    Text("全部余额合计").tag("total")
                    Text("仅图标").tag("none")
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                if AIProvider(rawValue: menuBarSource)?.usesQuota == true {
                    Picker("配额口径", selection: $menuBarQuotaScope) {
                        Text("本周剩余").tag("weekly")
                        Text("5 小时窗口剩余").tag("window")
                    }
                }
                Text("金额制服务商显示剩余余额；配额制（Kimi Code 等）按所选口径显示剩余百分比。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("数据") {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("清除所有数据…", systemImage: "trash")
                }
                Text("清除所有账户、API Key、余额历史与已导入的用量数据，恢复到首次安装状态。清除后需重新配置 API Key 并重新导入数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("余额数据来自各平台官方接口。除 DeepSeek 支持导入精确用量外，各平台的 token 数为按余额下降量与历史比率换算的估算值，精确用量请以平台控制台为准。Claude / Codex 需填写本机对应 CLI 登录凭证中的 access token。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background(HideScrollIndicators()) // Form 滚动区同样隐藏传统滚动条
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .alert("添加\(addAccountAlertProvider?.displayName ?? "")账户", isPresented: addingAccountPresented) {
            TextField("账户名称（如：主账号）", text: $accountNameInput)
            Button("添加") {
                if let provider = addAccountAlertProvider {
                    store.addAccount(provider: provider, name: accountNameInput)
                }
                addAccountAlertProvider = nil
            }
            Button("取消", role: .cancel) { addAccountAlertProvider = nil }
        }
        .alert("重命名账户", isPresented: renamingAccountPresented) {
            TextField("账户名称", text: $accountNameInput)
            Button("保存") {
                if let account = renamingAccount {
                    store.renameAccount(account, name: accountNameInput)
                }
                renamingAccount = nil
            }
            Button("取消", role: .cancel) { renamingAccount = nil }
        }
        .confirmationDialog(
            "删除账户「\(deletingAccount?.name ?? "")」？",
            isPresented: deletingAccountPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let account = deletingAccount {
                    store.removeAccount(account)
                }
                deletingAccount = nil
            }
            Button("取消", role: .cancel) { deletingAccount = nil }
        } message: {
            Text("将同时删除该账户下的所有 API Key、余额历史与已导入的用量数据。")
        }
        .confirmationDialog(
            "清除所有数据？",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { store.clearAllData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有账户、API Key 与用量数据将被删除，App 恢复到首次安装状态。此操作不可撤销。")
        }
        .alert("需要登录官网账号", isPresented: Binding(
            get: { loginPromptAccount != nil },
            set: { if !$0 { loginPromptAccount = nil } }
        )) {
            Button("登录…") {
                if let account = loginPromptAccount {
                    openSyncLogin(for: account)
                }
                loginPromptAccount = nil
            }
            Button("取消", role: .cancel) { loginPromptAccount = nil }
        } message: {
            Text("官方接口需要\(loginPromptAccount?.provider.displayName ?? "")官网登录态（仅保存在本机）。在弹出的窗口中完成账号登录后，会自动继续同步设置。")
        }
        .sheet(item: $syncAccount) { account in
            SyncMonthSheet(account: account)
                .environmentObject(store)
        }
    }

    /// 打开官网登录窗口，登录成功后保存该账户的登录态并直接进入同步月份选择
    private func openSyncLogin(for account: ProviderAccount) {
        let mode: SyncLoginWindowController.Mode = account.provider == .mimo ? .mimo : .deepseek
        SyncLoginWindowController.shared.show(mode: mode) { token in
            store.saveSyncToken(token, for: account)
            syncAccount = account
        }
    }

    // MARK: - 账户块

    @ViewBuilder
    private func accountBlock(_ account: ProviderAccount, provider: AIProvider) -> some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(provider.accentColor)
            Text(account.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button {
                accountNameInput = account.name
                renamingAccount = account
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("重命名账户")
            Button(role: .destructive) {
                deletingAccount = account
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("删除账户及其所有数据")
        }

        // 自定义接口（自定义模型）：账户级查询地址
        if provider.usesCustomEndpoint {
            TextField("查询接口地址（返回 JSON 的余额/额度接口）", text: endpointBinding(for: account))
                .textFieldStyle(.roundedBorder)
        }

        // 金额制服务商：累计消费校准基数（注册至今、导入数据覆盖不到的历史消费）
        if !provider.usesQuota {
            HStack {
                Text("累计消费校准")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("未设置", text: cumulativeBaseBinding(for: account))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("元")
                    .foregroundStyle(.secondary)
            }
            Text("看板的累计消费 = 校准值 + 已导入 + 实时消耗。在平台控制台查到注册至今的总消费后填入，可补齐导入数据之前的历史。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        // 官网用量同步（DeepSeek / 小米 MiMo：登录后选注册月份，自动拉取全部历史）
        if provider.supportsWebSync {
            HStack {
                Text("官网用量同步")
                    .foregroundStyle(.secondary)
                Spacer()
                if store.syncToken(for: account) != nil {
                    Button("重新登录…") {
                        openSyncLogin(for: account)
                    }
                    .help("已保存本账户的官网登录态；登录态不属于本账户或已失效时，点此重新登录")
                }
                Button("选择月份并同步…") {
                    if store.syncToken(for: account) == nil {
                        loginPromptAccount = account
                    } else {
                        syncAccount = account
                    }
                }
            }
            Text(provider == .mimo
                 ? "选择账户注册月份后，自动从小米 MiMo 开放平台拉取该月至今的全部用量（API 计费与 Token Plan 套餐分开统计，按天精度）。"
                 : "选择账户注册月份后，自动从 DeepSeek 官网拉取该月至今的全部用量（官方接口单次最多 30 天，会自动分段）；今天/昨天为逐小时精度，无需再手动导出 ZIP。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        ForEach(store.keys(for: account)) { key in
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                Text(key.label)
                    .lineLimit(1)
                Spacer()
                Text(store.maskedAPIKey(for: key))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    store.removeKey(key)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除此 Key")
            }
        }

        TextField("备注（如：工作 Key）", text: labelBinding(for: account.id))
            .textFieldStyle(.roundedBorder)
        SecureField("API Key / 凭证", text: keyBinding(for: account.id))
            .textFieldStyle(.roundedBorder)
        HStack {
            if let url = provider.apiKeyURL {
                Link("获取 API Key ↗", destination: url)
                    .font(.caption)
            }
            Spacer()
            Button("添加") {
                store.addKey(
                    provider: provider,
                    accountID: account.id,
                    label: newLabels[account.id] ?? "",
                    apiKey: newKeys[account.id] ?? ""
                )
                newLabels[account.id] = ""
                newKeys[account.id] = ""
            }
            .disabled((newKeys[account.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - 绑定

    private var addingAccountPresented: Binding<Bool> {
        Binding(
            get: { addAccountAlertProvider != nil },
            set: { if !$0 { addAccountAlertProvider = nil } }
        )
    }

    private var renamingAccountPresented: Binding<Bool> {
        Binding(
            get: { renamingAccount != nil },
            set: { if !$0 { renamingAccount = nil } }
        )
    }

    private var deletingAccountPresented: Binding<Bool> {
        Binding(
            get: { deletingAccount != nil },
            set: { if !$0 { deletingAccount = nil } }
        )
    }

    private func labelBinding(for accountID: UUID) -> Binding<String> {
        Binding(
            get: { newLabels[accountID] ?? "" },
            set: { newLabels[accountID] = $0 }
        )
    }

    private func keyBinding(for accountID: UUID) -> Binding<String> {
        Binding(
            get: { newKeys[accountID] ?? "" },
            set: { newKeys[accountID] = $0 }
        )
    }

    private func endpointBinding(for account: ProviderAccount) -> Binding<String> {
        Binding(
            get: { account.endpoint ?? "" },
            set: { store.updateAccountEndpoint(account, endpoint: $0) }
        )
    }

    /// 累计消费校准：文本留在本地 @State（输入过程不被回显打断），数值实时解析入库
    private func cumulativeBaseBinding(for account: ProviderAccount) -> Binding<String> {
        Binding(
            get: {
                if let text = baseInputs[account.id] { return text }
                guard let base = account.cumulativeBase else { return "" }
                return base.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(base))
                    : String(format: "%.2f", base)
            },
            set: { text in
                baseInputs[account.id] = text
                let parsed = Double(text.trimmingCharacters(in: .whitespaces))
                store.updateAccountCumulativeBase(account, base: parsed)
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { store.refreshInterval },
            set: { store.refreshInterval = $0 }
        )
    }
}

/// 服务商选项卡条：胶囊按钮按行平铺，数量多时自动换行（不藏横向滚动条）。
private struct ProviderTabBar: View {
    @Binding var selection: String

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(AIProvider.allCases) { provider in
                let selected = selection == provider.rawValue
                Button {
                    selection = provider.rawValue
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(provider.accentColor)
                            .frame(width: 7, height: 7)
                        Text(provider.displayName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        selected ? provider.accentColor.opacity(0.16) : Color.clear,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                selected ? provider.accentColor.opacity(0.5) : Color.secondary.opacity(0.2),
                                lineWidth: 0.5
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 官网用量同步（选注册月份）

/// 选择账户注册月份后，自动从 DeepSeek 官网分月拉取该月至今的全部用量。
/// 官方接口单次最多 30 天（自动分段）；今天/昨天用单日查询拿逐小时数据。
private struct SyncMonthSheet: View {
    let account: ProviderAccount
    @EnvironmentObject private var store: BalanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var year: Int
    @State private var month: Int
    @State private var syncing = false
    @State private var stage = ""
    @State private var outcome: String?
    @State private var failed = false

    init(account: ProviderAccount) {
        self.account = account
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        _year = State(initialValue: comps.year ?? 2026)
        _month = State(initialValue: comps.month ?? 1)
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var currentMonth: Int { Calendar.current.component(.month, from: Date()) }
    /// 可选月份不超过当前月
    private var futureMonthSelected: Bool {
        year > currentYear || (year == currentYear && month > currentMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从官网同步用量")
                .font(.title3.weight(.bold))
            Text(account.provider == .mimo
                 ? "选择「\(account.name)」的账户注册月份，将从小米 MiMo 开放平台拉取该月至今的全部用量（API 计费与 Token Plan 套餐分开统计，按天精度；同时带回官网口径的累计消费与余额）。"
                 : "选择「\(account.name)」的账户注册月份，将从 DeepSeek 官网拉取该月至今的全部用量数据（官方接口单次最多 30 天，会自动分段拉取；今天/昨天为逐小时精度）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Picker("年", selection: $year) {
                    // MiMo 平台 2025 年才上线，更早年份没有数据
                    ForEach((account.provider == .mimo ? 2025 : 2023)...currentYear, id: \.self) { Text("\($0) 年").tag($0) }
                }
                Picker("月", selection: $month) {
                    ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            if syncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let outcome {
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if failed, store.syncToken(for: account) == nil {
                    Button("重新登录并继续") { relogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncing)
                }
                Button("关闭") { dismiss() }
                    .disabled(syncing)
                Button(syncing ? "同步中…" : "开始同步") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncing || futureMonthSelected || store.syncToken(for: account) == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func relogin() {
        let mode: SyncLoginWindowController.Mode = account.provider == .mimo ? .mimo : .deepseek
        SyncLoginWindowController.shared.show(mode: mode) { [self] token in
            store.saveSyncToken(token, for: account)
            failed = false
            outcome = nil
            start()
        }
    }

    private func start() {
        guard let token = store.syncToken(for: account) else {
            failed = true
            outcome = "登录态缺失，请关闭后重新选择同步。"
            return
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        let monthStart = Calendar.current.date(from: comps) ?? Date()
        syncing = true
        failed = false
        outcome = nil
        if account.provider == .mimo {
            startMimo(monthStart: monthStart, rawSession: token)
        } else {
            startDeepSeek(monthStart: monthStart, token: token)
        }
    }

    private func startDeepSeek(monthStart: Date, token: String) {
        Task {
            do {
                let result = try await UsageSyncService.sync(fromMonth: monthStart, token: token) { label in
                    Task { @MainActor in stage = "正在拉取 \(label) …" }
                }
                await MainActor.run {
                    store.applySyncedUsage(result, into: account)
                    syncing = false
                    stage = ""
                    let days = Set(result.records.map { Calendar.current.startOfDay(for: $0.day) }).count
                    outcome = "同步完成：共 \(days) 天、\(result.records.count) 条记录，今天/昨天为逐小时数据。"
                }
            } catch {
                await finishWithError(error)
            }
        }
    }

    private func startMimo(monthStart: Date, rawSession: String) {
        guard let data = rawSession.data(using: .utf8),
              let session = try? JSONDecoder().decode(MimoSyncService.Session.self, from: data) else {
            failed = true
            syncing = false
            outcome = "登录态缺失，请关闭后重新选择同步。"
            return
        }
        Task {
            do {
                let output = try await MimoSyncService.sync(fromMonth: monthStart, session: session) { label in
                    Task { @MainActor in stage = "正在拉取 \(label) …" }
                }
                await MainActor.run {
                    // 空结果不落库（与 DeepSeek 一致）：避免选错月份时清掉账户已有数据
                    if !output.records.isEmpty {
                        store.applySyncedUsage(
                            UsageSyncService.SyncResult(records: output.records, coverageEnd: output.coverageEnd),
                            into: account
                        )
                    }
                    // 官网口径的注册至今累计消费：用户未手动校准过时自动填入
                    var extra = ""
                    if account.cumulativeBase == nil, let total = output.totalCost, total > 0 {
                        store.updateAccountCumulativeBase(account, base: total)
                        extra += "累计消费 \(Formatting.cny(total))（官网口径）已自动填入校准。"
                    }
                    if let balance = output.balance {
                        store.applyMimoBalance(balance, currency: output.currency ?? "CNY", to: account)
                        extra += "当前余额 \(Formatting.cny(balance))。"
                    }
                    syncing = false
                    stage = ""
                    let days = Set(output.records.map { Calendar.current.startOfDay(for: $0.day) }).count
                    outcome = output.records.isEmpty
                        ? "该时间段没有用量数据，已有数据未改动。\(extra)"
                        : "同步完成：共 \(days) 天、\(output.records.count) 条记录（含 Token Plan 套餐用量）。\(extra)"
                }
            } catch {
                await finishWithError(error)
            }
        }
    }

    @MainActor
    private func finishWithError(_ error: Error) {
        syncing = false
        stage = ""
        failed = true
        if case UsageSyncError.invalidToken = error {
            store.clearSyncToken(for: account)
            outcome = "登录态已失效，点击「重新登录并继续」。"
        } else {
            outcome = error.localizedDescription
        }
    }
}
