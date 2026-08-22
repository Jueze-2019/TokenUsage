import AppKit
import SwiftUI

/// 图标按钮的按压缩放回弹动效（label 自带样式的 borderless 场景使用）。
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ScaleButtonStyle {
    static var scale: ScaleButtonStyle { ScaleButtonStyle() }
}

/// 卡片悬停反馈：背景提亮 + 细描边 + 轻微上浮。
/// 只作用在渲染层（scaleEffect 不改布局），列表内使用不会引起抖动。
struct InteractiveCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                .quaternary.opacity(hovering ? 0.85 : 0.5),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(hovering ? 0.12 : 0), lineWidth: 0.5)
            )
            .scaleEffect(hovering ? 1.012 : 1)
            .animation(.spring(duration: 0.28), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 看板卡片背景（半透明灰底 + 悬停提亮 / 微上浮反馈）
    func interactiveCardBackground(cornerRadius: CGFloat = 10) -> some View {
        modifier(InteractiveCardModifier(cornerRadius: cornerRadius))
    }
}

/// 服务商状态圆点：刷新数据时缓慢脉动，平时静止。
struct PulsingDot: View {
    let color: Color
    var active: Bool = false
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.4 : 1)
            .opacity(pulsing ? 0.55 : 1)
            .animation(.default, value: active)
            .animation(
                active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = active }
            .onChange(of: active) { _, on in pulsing = on }
    }
}

/// 隐藏所在 NSScrollView 的滚动条。SwiftUI 的 `.scrollIndicators(.hidden)`
/// 在该面板层级下不生效（系统接鼠标显示传统滚动条时仍占 15pt 宽），
/// 直接在 AppKit 层关掉 scroller：不占空间，滚轮滚动不受影响。
struct HideScrollIndicators: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.applyWithRetry()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI 更新内容尺寸时会重设 scroller 可见性，每次更新都重新关掉
        context.coordinator.view = nsView
        context.coordinator.applyWithRetry()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: NSView?
        private weak var observedClipView: NSView?
        private var retries = 0

        /// 带延迟的重试：MenuBarExtra 面板懒挂载，立即重试会在视图进窗口前耗尽次数
        func applyWithRetry() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let view = self.view else { return }
                if let scrollView = Self.findScrollView(from: view) {
                    Self.disable(scrollView)
                    self.retries = 0
                    self.observeClipView(of: scrollView)
                } else if self.retries < 30 {
                    self.retries += 1
                    self.applyWithRetry()
                }
            }
        }

        /// 监听 clipView 尺寸变化自愈：SwiftUI 重新打开 scroller 时 clipView 会缩小，
        /// 借此立刻把 scroller 再关掉
        private func observeClipView(of scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            guard observedClipView !== clipView else { return }
            if let old = observedClipView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: old
                )
            }
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            observedClipView = clipView
        }

        @objc private func clipViewBoundsChanged(_ note: Notification) {
            guard let clipView = note.object as? NSClipView,
                  let scrollView = clipView.superview as? NSScrollView else { return }
            if scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller {
                Self.disable(scrollView)
            }
        }

        func stop() {
            if let old = observedClipView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: old
                )
            }
        }

        /// 代表视图作为 ScrollView 的 background 挂在 scrollview 旁边而非内部，
        /// 因此向上找不到，需从窗口顶层向下找第一个 NSScrollView（面板只有一个滚动区）
        private static func findScrollView(from view: NSView) -> NSScrollView? {
            guard let root = view.window?.contentView else { return nil }
            return firstScrollView(in: root)
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for sub in view.subviews {
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        private static func disable(_ scrollView: NSScrollView) {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            // 万一 SwiftUI 又打开了 scroller：overlay 样式不预留宽度，闲置自动隐藏
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }
}
