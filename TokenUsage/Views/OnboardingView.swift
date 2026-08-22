import AppKit
import SwiftUI

/// 首次安装引导：欢迎 → 添加 API Key（可多个、多服务商）→ 导入 DeepSeek 用量 ZIP（可选）→ 完成。
/// 仅在「无任何已配置 Key 且未完成过引导」时，于 App 启动后自动弹出一次；
/// 关闭窗口即视为完成（空状态页有入口随时进设置）。
struct OnboardingView: View {
    @EnvironmentObject private var store: BalanceStore
    /// 关闭窗口（由控制器注入）
    var onFinish: () -> Void = {}

    @State private var step = 0
    @State private var provider: AIProvider = .deepseek
    @State private var accountName = ""
    @State private var label = ""
    @State private var apiKey = ""
    @State private var addedKeys = 0
    @State private var addedDeepseek = false
    @State private var importSummary: String?
    @State private var importAccountID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcomeStep
                case 1: addKeyStep
                case 2: importStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(width: 420, height: 400)
        .animation(.smooth(duration: 0.3), value: step)
    }

    // MARK: - 步骤 0：欢迎

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text("欢迎使用 Token 用量")
                .font(.title2.weight(.bold))
            Text("在菜单栏实时查看 DeepSeek / Kimi / GLM / MiniMax /\nClaude / Codex 等服务商的余额、额度与用量趋势。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("开始设置") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("暂时跳过") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    // MARK: - 步骤 1：添加 API Key

    private var addKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加 API Key")
                .font(.title3.weight(.bold))
            Text("至少添加一个服务商的 Key。同一服务商有多个账号时，填不同的账户名称即可分开统计。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("服务商", selection: $provider) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()

            TextField("账户名称（可选，如：主账号）", text: $accountName)
                .textFieldStyle(.roundedBorder)
            TextField("Key 备注（可选，如：工作 Key）", text: $label)
                .textFieldStyle(.roundedBorder)
            SecureField("API Key / 凭证", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            if let url = provider.apiKeyURL {
                Link("获取 \(provider.displayName) 的 API Key ↗", destination: url)
                    .font(.caption)
            }
            Text(provider.credentialHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if addedKeys > 0 {
                Label("已添加 \(addedKeys) 个 Key", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()
            HStack {
                Button("添加") { addKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button(addedKeys > 0 ? "下一步" : "跳过，稍后再说") { next() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func addKey() {
        let trimmedName = accountName.trimmingCharacters(in: .whitespaces)
        let account: ProviderAccount
        if !trimmedName.isEmpty {
            account = store.accounts(for: provider).first { $0.name == trimmedName }
                ?? store.addAccount(provider: provider, name: trimmedName)
        } else {
            account = store.accounts(for: provider).first
                ?? store.addAccount(provider: provider, name: "默认账户")
        }
        store.addKey(provider: provider, accountID: account.id, label: label, apiKey: apiKey)
        addedKeys += 1
        if provider == .deepseek { addedDeepseek = true }
        apiKey = ""
        label = ""
    }

    private func next() {
        step = addedDeepseek ? 2 : 3
    }

    // MARK: - 步骤 2：导入用量 ZIP（可选）

    private var deepseekAccounts: [ProviderAccount] { store.accounts(for: .deepseek) }

    private var importStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入 DeepSeek 用量数据")
                .font(.title3.weight(.bold))
            Text("在 platform.deepseek.com/usage 导出用量 ZIP，导入后即可看到分模型、分 Key 的 token 用量与消费图表。此步可选，之后随时能在看板右上角导入。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if deepseekAccounts.count > 1 {
                Picker("导入到账户", selection: $importAccountID) {
                    ForEach(deepseekAccounts) { account in
                        Text(account.name).tag(account.id as UUID?)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("选择 ZIP 文件…") { importZIP() }
                if let importSummary {
                    Label(importSummary, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = store.importError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button(importSummary == nil ? "跳过" : "下一步") { step = 3 }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            if importAccountID == nil { importAccountID = deepseekAccounts.first?.id }
        }
    }

    private func importZIP() {
        // LSUIElement 应用未激活时 NSOpenPanel 可能不弹出/落到后面，先激活
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let account = deepseekAccounts.first(where: { $0.id == importAccountID })
            ?? deepseekAccounts.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        store.importUsage(from: url, into: account)
        if accessing { url.stopAccessingSecurityScopedResource() }
        if store.importError == nil {
            importSummary = "已导入 \(store.usageRecords.forAccount(account.id).count) 条记录"
        }
    }

    // MARK: - 步骤 3：完成

    private var doneStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce)
            Text("设置完成")
                .font(.title2.weight(.bold))
            Text("点击菜单栏图标即可查看余额与用量看板。\n账户、Key、图表模块都能在设置中随时调整。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("开始使用") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        onFinish()
    }
}

/// 引导窗口控制器：LSUIElement 下 SwiftUI 场景窗口不可靠，统一手动 NSWindow。
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    @MainActor
    func showIfNeeded(store: BalanceStore) {
        guard !store.hasAnyKey,
              !UserDefaults.standard.bool(forKey: "onboardingDone") else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(onFinish: { [weak self] in
            self?.window?.close()
        })
        .environmentObject(store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "欢迎使用 Token 用量"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // 无论是否走完向导，关闭后都不再自动弹出
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        window = nil
    }
}
