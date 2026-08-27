import AppKit
import SwiftUI

/// 菜单栏弹层主界面。
struct MenuBarContentView: View {
    @EnvironmentObject private var store: BalanceStore
    @AppStorage("usageRange") private var usageRange: UsageRange = .week
    /// 服务商多选（JSON 编码的 Set<String>）。
    /// 存储语义：空串 = 从未设置（默认全部）；「[]」= 用户全不勾（放空）；其余 = 勾选项
    @AppStorage("providerSelection") private var providerSelectionRaw: String = ""
    /// 离屏渲染（TU_HEADLESS）跳过入场动画，否则截图会抓到半透明中间帧
    @State private var cardsAppeared = ProcessInfo.processInfo.environment["TU_HEADLESS"] != nil
    @State private var contentHeight: CGFloat = 0
    /// 更新提示横幅（本次运行内可关闭）
    @State private var updateBannerDismissed = false
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        VStack(spacing: 12) {
            header
            if let updateVersion = updater.availableVersion, !updateBannerDismissed {
                updateBanner(version: updateVersion)
            }
            filterRow
            Divider()
            content
            Divider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
        .background(PanelResizer(hasContent: !configuredProviders.isEmpty, contentHeight: contentHeight))
    }

    /// 服务商多选的原始选择；nil = 从未设置（默认全部），空集 = 全不勾（放空）
    private var selectedProviders: Set<String>? {
        get {
            guard !providerSelectionRaw.isEmpty,
                  let data = providerSelectionRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue else { providerSelectionRaw = ""; return }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            providerSelectionRaw = String(decoding: data, as: UTF8.self)
        }
    }

    /// 已配置 Key 的服务商
    private var availableProviders: [AIProvider] {
        store.providerOrder.filter { !store.keys(for: $0).isEmpty }
    }

    /// 当前展示的服务商：nil = 全部；空集 = 全不勾（面板放空）；其余 = 勾选的 ∩ 已配置
    private var configuredProviders: [AIProvider] {
        guard let selection = selectedProviders else { return availableProviders }
        return availableProviders.filter { selection.contains($0.rawValue) }
    }

    /// 服务商多选下拉的当前值文案
    private var providerSelectionTitle: String {
        guard let selection = selectedProviders else { return "全部" }
        let valid = availableProviders.filter { selection.contains($0.rawValue) }
        if valid.isEmpty { return "未选择" }
        if valid.count == 1 { return valid[0].displayName }
        return "已选 \(valid.count) 个"
    }

    /// LSUIElement 菜单栏应用里 SwiftUI 的 openSettings/showSettingsWindow:
    /// 经常因 App 未激活而弹不出窗口。直接用手动 NSWindow，行为确定、单一窗口。
    private func openSettingsWindow() {
        SettingsWindowController.shared.show(store: store)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: store.isRefreshing)
            Text("Token 用量")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
            }
            .buttonStyle(.scale)
            .disabled(store.isRefreshing)
            .help("立即刷新")
            if let last = store.lastRefresh {
                Text(last, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 发现新版本时的顶部横幅：一键下载安装，或本次运行内关闭
    private func updateBanner(version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
            Text("发现新版本 v\(version)")
                .font(.callout)
                .fontWeight(.medium)
            Spacer()
            if updater.state == .downloading {
                Text("下载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if updater.state == .installing {
                Text("安装中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("更新") {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    updateBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("本次不再提示")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filterRow: some View {
        // 对齐 DeepSeek「时间维度」下拉：近7天/近30天/本月/上月；
        // 服务商多选：勾一个看一个，勾多个看多个，全不勾 = 全部
        HStack(spacing: 8) {
            Menu {
                ForEach(UsageRange.allCases) { range in
                    Button {
                        usageRange = range
                    } label: {
                        if range == usageRange {
                            Label(range.title, systemImage: "checkmark")
                        } else {
                            Text(range.title)
                        }
                    }
                }
            } label: {
                // 注意：Menu label 只完整渲染单个 Text（HStack 多元素会被拍扁、丢样式），
                // 因此名称与当前值拼接成一个 Text
                (Text("时间维度 ").foregroundStyle(.secondary)
                    + Text(usageRange.title).fontWeight(.medium))
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            if availableProviders.count > 1 { providerFilterMenu }
            Spacer()
        }
    }

    /// 服务商多选下拉：原生勾选标识；「全部」是总开关——勾上 = 全部展示，
    /// 取消 = 全不勾（面板放空）；单项勾满全部时自动归一为默认「全部」
    private var providerFilterMenu: some View {
        Menu {
            Toggle("全部", isOn: Binding(
                get: { selectedProviders == nil },
                set: { on in selectedProviders = on ? nil : [] }
            ))
            Divider()
            ForEach(availableProviders) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { selectedProviders?.contains(provider.rawValue) ?? true },
                    set: { _ in toggleProviderSelection(provider.rawValue) }
                ))
            }
        } label: {
            (Text("服务商 ").foregroundStyle(.secondary)
                + Text(providerSelectionTitle).fontWeight(.medium))
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 切换单个服务商的勾选：在默认「全部」上点击 = 取消勾选它（其余全选）；
    /// 勾满全部时归一化为默认（nil）；全部取消 = 空集，看板放空
    private func toggleProviderSelection(_ rawValue: String) {
        let all = Set(availableProviders.map(\.rawValue))
        var selection = selectedProviders ?? all
        if selection.contains(rawValue) {
            selection.remove(rawValue)
        } else {
            selection.insert(rawValue)
        }
        selectedProviders = selection == all ? nil : selection
    }

    @ViewBuilder
    private var content: some View {
        if availableProviders.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("尚未配置 API Key")
                    .font(.headline)
                Text("在设置中添加服务商的 API Key（支持多个账户），\n即可实时查看余额、额度与用量趋势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("打开设置…") { openSettingsWindow() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if configuredProviders.isEmpty {
            // 用户把服务商全部取消勾选：面板放空，只留提示
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("未选择服务商")
                    .font(.subheadline.weight(.medium))
                Text("在上方「服务商」下拉中勾选要展示的看板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(configuredProviders.enumerated()), id: \.element.id) { index, provider in
                            ProviderCardView(provider: provider, range: usageRange)
                                .opacity(cardsAppeared ? 1 : 0)
                                .offset(y: cardsAppeared ? 0 : 10)
                                .animation(
                                    .smooth(duration: 0.45).delay(Double(index) * 0.08),
                                    value: cardsAppeared
                                )
                        }
                    }
                    .padding(.vertical, 2)
                    .id("panelTop")
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PanelContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .scrollIndicators(.hidden) // 覆盖式滚动条会挡住看板右侧内容
                .background(HideScrollIndicators()) // .hidden 在该层级不生效，AppKit 层关掉 scroller
                .onPreferenceChange(PanelContentHeightKey.self) { newHeight in
                    // 等值回写 @State 也会触发整面板重渲染，加阈值守卫
                    if abs(newHeight - contentHeight) > 0.5 { contentHeight = newHeight }
                }
                .frame(minHeight: 140, idealHeight: 560, maxHeight: .infinity)
                .onAppear {
                    // 每次打开面板时重播入场动画（离屏渲染跳过，直接终帧）
                    guard ProcessInfo.processInfo.environment["TU_HEADLESS"] == nil else {
                        cardsAppeared = true
                        return
                    }
                    cardsAppeared = false
                    withAnimation { cardsAppeared = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    // 面板窗口跨开关保留滚动位置，重开时可能停在上次滚动处，
                    // 导致顶部卡片被裁掉一截——每次激活回到顶部
                    proxy.scrollTo("panelTop", anchor: .top)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openSettingsWindow()
            } label: {
                Label("设置", systemImage: "gear")
            }
            .buttonStyle(.scale)
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.scale)
            .foregroundStyle(.secondary)
        }
    }
}

/// 设置窗口兜底控制器：SwiftUI Settings 场景在 LSUIElement 应用中偶发
/// 建不出窗口时，用 AppKit 手动创建。
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(store: BalanceStore) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView().environmentObject(store)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // 宽度固定 460，高度可拖拽，默认半屏
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        window.setContentSize(NSSize(width: 460, height: (screenHeight / 2).rounded()))
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.contentMaxSize = NSSize(width: 460, height: screenHeight)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

/// 面板滚动区内容的实测高度（含其内边距），用于计算默认面板高度
private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 让 MenuBarExtra(.window) 面板可纵向拖拽调高（宽度固定 380）。
/// MenuBarExtra 的窗口默认按内容自适应且不带 .resizable，这里拿到底层
/// NSWindow 补上 resize 能力，并记住用户拖拽的高度。
/// 高度策略：
/// - 最大高度 = 实测内容高度 + 固定 chrome（且不超过屏幕可视高度）——内容不够就拖不长，
///   简洁模式下显示完所有内容即停止，不会再拖出空白区域；
/// - 点击简洁/详细切换（cardMode 变化）时清除用户拖拽记忆，窗口随内容重新收放
///   （简洁缩小、详细放大，上限屏幕高度）；
/// - 只允许下边框拖拽：上边框拖动时顶边会被拉回菜单栏锚点位置；
/// - 无数据（首次打开）不强制高度，按内容自适应，避免空白区域透出桌面。
private struct PanelResizer: NSViewRepresentable {
    let hasContent: Bool
    let contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hasContent = hasContent
        context.coordinator.contentHeight = contentHeight
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hasContent = hasContent
        context.coordinator.contentHeight = contentHeight
        context.coordinator.attach(nsView)
        context.coordinator.apply()
    }

    final class Coordinator: NSObject {
        var hasContent = true
        var contentHeight: CGFloat = 0
        private weak var view: NSView?
        private weak var observedWindow: NSWindow?
        private var retries = 0
        /// 顶边锚点（菜单栏侧）：只允许下边框拖拽，上边框拖动时据此拉回
        private var anchorTop: CGFloat?
        /// 简洁/详细切换后待执行的「随内容收放」
        private var pendingFit = false
        /// 各服务商简洁/详细模式的快照，用于检测模式切换
        private var modeSignature = ""

        func attach(_ view: NSView) {
            self.view = view
            retries = 0
            configure()
        }

        /// 数据或实测高度变化后重新套用尺寸（由 updateNSView 驱动）
        func apply() {
            guard let window = view?.window else { return }
            applySizing(window)
            restoreHeight(window)
        }

        private func configure() {
            guard let window = view?.window else {
                // 视图还没挂进窗口时稍候重试
                guard retries < 20 else { return }
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.configure()
                }
                return
            }
            applySizing(window)

            if observedWindow !== window {
                observedWindow = window
                modeSignature = currentModeSignature()
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(didResize(_:)),
                    name: NSWindow.didEndLiveResizeNotification,
                    object: window
                )
                // MenuBarExtra 每次打开都会按内容自适应尺寸，覆盖我们设置的高度，
                // 且发生在激活之后——激活时（含延迟补一次）恢复目标高度
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(didBecomeKey(_:)),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                // 拖拽中锁定顶边（只允许下边框）；非拖拽的尺寸变化（系统 refit）拉回目标高度
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResize(_:)),
                    name: NSWindow.didResizeNotification,
                    object: window
                )
                // 简洁/详细切换写在 UserDefaults（cardMode.*）：监听后让窗口随内容收放
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(defaultsChanged(_:)),
                    name: UserDefaults.didChangeNotification,
                    object: nil
                )
            }
            restoreHeight(window)
        }

        // MARK: - 尺寸策略

        /// 内容适配高度：实测内容 + 固定 chrome，夹在 [220, 屏幕可视高度]
        private func fitHeight(for window: NSWindow) -> CGFloat {
            let content = contentHeight > 0 ? contentHeight + 156 : 560
            // 离屏渲染：不受屏幕高度限制，整面板完整入图
            if ProcessInfo.processInfo.environment["TU_HEADLESS"] != nil {
                return min(max(content, 220), 8_000)
            }
            let screenMax = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1_400
            return min(max(content, 220), screenMax)
        }

        private func applySizing(_ window: NSWindow) {
            // 离屏渲染：不夹高度，由渲染工具拉满窗口整面板截图
            if ProcessInfo.processInfo.environment["TU_HEADLESS"] != nil {
                window.styleMask.insert(.resizable)
                window.minSize = NSSize(width: 380, height: 220)
                window.maxSize = NSSize(width: 380, height: 8_000)
                return
            }
            let fit = fitHeight(for: window)
            window.styleMask.insert(.resizable)
            // 最小高度同样不超过内容适配高度，简洁模式下小内容不会残留空白
            let minHeight = hasContent ? min(360, fit) : min(220, fit)
            window.minSize = NSSize(width: 380, height: minHeight)
            window.maxSize = NSSize(width: 380, height: max(fit, minHeight))
        }

        /// 目标高度：简洁/详细刚切换过 → 随内容收放；用户拖过的用拖拽值（夹到内容上限）；
        /// 无数据不强制（nil = 系统按内容自适应）；否则按内容适配高度
        private func targetHeight(for window: NSWindow) -> CGFloat? {
            // 离屏渲染：不主动纠高，窗口尺寸由渲染工具控制
            if ProcessInfo.processInfo.environment["TU_HEADLESS"] != nil { return nil }
            let fit = fitHeight(for: window)
            if pendingFit, hasContent { return fit }
            let saved = UserDefaults.standard.double(forKey: "panelHeight")
            if saved >= 220 { return min(CGFloat(saved), fit) }
            guard hasContent else { return nil }
            return fit
        }

        /// 恢复目标高度；保持窗口上边沿（菜单栏锚点侧）不动
        private func restoreHeight(_ window: NSWindow) {
            guard let target = targetHeight(for: window) else { return }
            pendingFit = false
            var frame = window.frame
            let delta = target - frame.size.height
            if abs(delta) > 0.5 {
                frame.size.height = target
                frame.origin.y -= delta
                window.setFrame(frame, display: false)
            }
            anchorTop = window.frame.maxY
        }

        // MARK: - 事件

        @objc private func didBecomeKey(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            restoreHeight(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
                guard let self, let window else { return }
                self.restoreHeight(window)
            }
        }

        @objc private func windowDidResize(_ note: Notification) {
            guard let window = note.object as? NSWindow, window.isVisible else { return }
            if window.inLiveResize {
                // 上边框禁止拖拽：顶边一旦被移动就拉回锚点（下边框拖动不改变顶边，不受影响）
                if let anchorTop, abs(window.frame.maxY - anchorTop) > 1 {
                    var frame = window.frame
                    frame.origin.y = anchorTop - frame.size.height
                    window.setFrame(frame, display: false)
                }
                return
            }
            restoreHeight(window)
        }

        @objc private func didResize(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            // 拖拽结束时的高度同样夹到内容上限（拖拽中 maxSize 已限制，这里是双保险）
            let fit = fitHeight(for: window)
            let height = min(window.frame.size.height, fit)
            UserDefaults.standard.set(Double(height), forKey: "panelHeight")
            anchorTop = window.frame.maxY
        }

        // MARK: - 简洁/详细切换联动

        private func currentModeSignature() -> String {
            AIProvider.allCases
                .map { UserDefaults.standard.string(forKey: "cardMode.\($0.rawValue)") ?? "detailed" }
                .joined(separator: ",")
        }

        @objc private func defaultsChanged(_ note: Notification) {
            let signature = currentModeSignature()
            guard signature != modeSignature else { return }
            modeSignature = signature
            // 清除拖拽记忆，标记随内容收放；内容高度变化由 updateNSView 驱动 apply()，
            // 延迟补一次兜底（布局尚未重测时用旧内容高度先收一次）
            UserDefaults.standard.removeObject(forKey: "panelHeight")
            pendingFit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.apply()
            }
        }
    }
}
