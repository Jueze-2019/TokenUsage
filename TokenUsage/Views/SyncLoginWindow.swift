import AppKit
import WebKit

/// 官网登录窗口：WKWebView 打开平台登录页，拿到登录态后回调并关闭窗口。
/// 仅用于官网用量同步接口的鉴权。
///
/// - DeepSeek：轮询 localStorage.userToken（官网前端登录成功后写入的会话凭证）。
/// - 小米 MiMo：轮询 cookie 中的 api-platform_serviceToken（小米 SSO 登录成功后种下），
///   命中后把 api-platform_serviceToken / ph / slh / userId 一并取出，编码为
///   MimoSyncService.Session 的 JSON 字符串回调。
///
/// 注意：WebView 使用非持久会话——不带出上一个账户的登录态（cookies/localStorage），
/// 保证每次打开都是干净的登录页（否则新账户同步会静默抓到旧账户的登录态）。
final class SyncLoginWindowController: NSObject {
    static let shared = SyncLoginWindowController()

    /// 登录模式：决定打开哪个平台、用哪种方式取登录态
    enum Mode {
        case deepseek
        case mimo

        var title: String {
            switch self {
            case .deepseek: return "登录 DeepSeek 官网"
            case .mimo: return "登录小米 MiMo 开放平台"
            }
        }

        var entryURL: URL {
            switch self {
            // 直接落在控制台用量页：未登录会被小米 SSO 接管，登录成功后回跳该页
            case .mimo: return URL(string: "https://platform.xiaomimimo.com/console/usage")!
            case .deepseek: return URL(string: "https://platform.deepseek.com/sign_in")!
            }
        }
    }

    private var window: NSWindow?
    private weak var webView: WKWebView?
    private var onToken: ((String) -> Void)?
    private var pollTimer: Timer?
    private var mode: Mode = .deepseek

    @MainActor
    func show(mode: Mode = .deepseek, onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        self.mode = mode
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = mode.title
        window.isReleasedWhenClosed = false
        window.center()
        webView.load(URLRequest(url: mode.entryURL))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.webView = webView

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch self.mode {
            case .deepseek: self.pollDeepSeekToken()
            case .mimo: self.pollMimoCookies()
            }
        }
    }

    /// DeepSeek：登录成功后官网前端会把 userToken 写入 localStorage，轮询取回
    private func pollDeepSeekToken() {
        webView?.evaluateJavaScript("localStorage.getItem('userToken')") { [weak self] value, _ in
            guard let raw = value as? String, !raw.isEmpty else { return }
            // 官网 storage 句柄的两种形态：裸 token 或 {"value":"...","__version__":"0"}；
            // 未登录/已退出时是 {"value":null,...}——继续轮询等待真正登录完成
            var token = raw
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard let inner = json["value"] as? String, !inner.isEmpty else { return }
                token = inner
            }
            DispatchQueue.main.async {
                self?.finish(token: token)
            }
        }
    }

    /// 小米 MiMo：SSO 回跳后服务端种下 api-platform_* 会话 cookie，轮询 cookieStore
    private func pollMimoCookies() {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let relevant = cookies.filter { $0.name.hasPrefix("api-platform_") || $0.name == "userId" }
            // cookie 值可能带首尾引号（前端读取时会 strip，保持一致）
            func value(of name: String) -> String? {
                relevant.first { $0.name == name }?.value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard let serviceToken = value(of: "api-platform_serviceToken"), !serviceToken.isEmpty,
                  let ph = value(of: "api-platform_ph"), !ph.isEmpty else { return }
            let session = MimoSyncService.Session(
                serviceToken: serviceToken,
                ph: ph,
                slh: value(of: "api-platform_slh"),
                userId: value(of: "userId")
            )
            guard let data = try? JSONEncoder().encode(session),
                  let raw = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.finish(token: raw)
            }
        }
    }

    @MainActor
    private func finish(token: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        let callback = onToken
        onToken = nil
        window?.close()
        window = nil
        callback?(token)
    }

    @MainActor
    func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        onToken = nil
        window?.close()
        window = nil
    }
}
