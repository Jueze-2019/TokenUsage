import AppKit
import SwiftUI

/// 离屏渲染菜单栏面板到 /tmp/panel_render.png，用于无头检查 UI。
@main
enum RenderPanel {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 清掉本工具自身偏好域的残留（上次渲染写入的 cardMode 等会泄漏进本次），
        // 保证每次渲染只反映 /tmp/tu_defaults.plist 的内容
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.removePersistentDomain(forName: "render_panel")

        // 同步主 App 的 UserDefaults（账户/Key 元数据等），复刻真实面板状态
        if let defaults = NSDictionary(contentsOfFile: "/tmp/tu_defaults.plist") as? [String: Any] {
            for (key, value) in defaults where !key.hasPrefix("NS") {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        let store = BalanceStore()
        let view = MenuBarContentView().environmentObject(store)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.setContentSize(NSSize(width: 380, height: 720))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)

        // 让 onAppear/动画/首轮刷新（含今天/昨天的轻量同步）跑完
        RunLoop.main.run(until: Date().addingTimeInterval(8))

        print("diag: keys=\(store.keys.count) accounts=\(store.accounts.count) records=\(store.usageRecords.count) dataKeys=\(store.dataByKey.count) lastRefresh=\(String(describing: store.lastRefresh))")

        guard let content = window.contentView else { exit(1) }
        print("diag: windowFrame=\(window.frame) contentBounds=\(content.bounds) fitting=\(content.fittingSize)")
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // ScrollView 的 documentView 才是完整内容（窗口被夹高时图表在可视区外），
        // 直接对 documentView 整幅截图；找不到滚动视图则退回 contentView
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }
        let capture = findScrollView(content)?.documentView ?? content
        print("diag2: captureBounds=\(capture.bounds)")
        guard let rep = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { exit(1) }
        capture.cacheDisplay(in: capture.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: URL(fileURLWithPath: "/tmp/panel_render.png"))
        print("rendered \(capture.bounds.size)")
    }
}
