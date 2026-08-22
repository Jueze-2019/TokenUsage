import SwiftUI

@main
struct TokenUsageApp: App {
    @StateObject private var store = BalanceStore()

    init() {
        // 本 App 内滚动条强制「滚动时才显示」：overlay 样式不占布局宽度、
        // 闲置自动隐藏（用户接鼠标时系统默认会显示常驻传统滚动条，挤占面板 15pt）。
        // 与面板里的 HideScrollIndicators 配合，双保险。
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        migrateSelectionSemantics()
    }

    /// 多选语义迁移（v2 起：空集 = 全不勾、看板放空；此前空集 = 全部）。
    /// 旧版会把「全部」持久化为 "[]"，直接套用新语义会让升级用户看到空看板，
    /// 因此一次性把存量的 "[]" 改写回 ""（未设置 = 默认全部），保持升级前后所见一致。
    private func migrateSelectionSemantics() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "selectionSemanticsV2") else { return }
        for key in defaults.dictionaryRepresentation().keys
        where key == "providerSelection"
            || key.hasPrefix("accountSelection.")
            || key.hasPrefix("keySelection.") {
            if defaults.string(forKey: key) == "[]" {
                defaults.set("", forKey: key)
            }
        }
        defaults.set(true, forKey: "selectionSemanticsV2")
    }

    var body: some Scene {
        // 菜单栏常驻入口（与控制中心同排的系统状态区）
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// 菜单栏图标 + 可配置的紧凑文本（设置 → 菜单栏）。
/// menuBarSource：total = 全部余额合计（默认）；none = 仅图标；
/// 其余为服务商 rawValue——金额制显示该服务商剩余余额，配额制（Kimi Code 等）显示剩余百分比。
/// menuBarQuotaScope：配额制口径，weekly = 本周剩余（默认），window = 5 小时窗口剩余。
private struct MenuBarLabel: View {
    @EnvironmentObject private var store: BalanceStore
    @AppStorage("menuBarSource") private var menuBarSource = "total"
    @AppStorage("menuBarQuotaScope") private var menuBarQuotaScope = "weekly"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            if let text = labelText {
                Text(text)
                    .monospacedDigit()
            }
        }
    }

    private var labelText: String? {
        switch menuBarSource {
        case "none":
            return nil
        case "total":
            return store.hasAnyData ? Formatting.compactCNY(store.totalBalance) : nil
        default:
            guard let provider = AIProvider(rawValue: menuBarSource) else { return nil }
            if provider.usesQuota {
                let quotas = store.keys(for: provider).compactMap { store.quota(for: $0) }
                guard !quotas.isEmpty else { return nil }
                let percents = quotas.map {
                    menuBarQuotaScope == "window" ? $0.windowRemainingPercent : $0.weeklyRemainingPercent
                }
                return "\(percents.reduce(0, +) / percents.count)%"
            }
            return store.hasAnyData(for: provider)
                ? Formatting.compactCNY(store.totalBalance(for: provider))
                : nil
        }
    }
}
