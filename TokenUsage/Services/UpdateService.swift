import AppKit
import Foundation

/// 基于 GitHub Releases 的自更新服务：检查最新版本、下载 zip、解压替换并重启 App。
///
/// 实现要点：
/// - 版本来源固定为本仓库 Releases，无需维护 appcast 之类的额外 feed；
/// - URLSession 下载不会带 quarantine 隔离属性，替换后的 App 可直接运行；
/// - 替换通过一段等待本进程退出后再执行的 shell 脚本完成（运行中的 bundle 不能原地覆盖），
///   脚本启动后本进程立即退出，由脚本完成 rm/mv/open 并清理自身。
/// 注意：主 App 不能启用 App Sandbox，否则无法 spawn 子进程替换 /Applications 下的自身。
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 已发现的新版本号（下载/安装期间 state 不再是 available，靠它维持横幅显示）
    @Published private(set) var availableVersion: String?

    private static let apiURL =
        URL(string: "https://api.github.com/repos/Jueze-2019/TokenUsage/releases/latest")!
    private static let assetName = "TokenUsage.zip"
    /// 已确认可下载的最新包地址（check 成功后填入）
    private var downloadURL: URL?

    /// 当前运行版本（Info.plist 的 CFBundleShortVersionString）
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 语义化版本比较：忽略 v/V 前缀，按 . 分段比数字，缺位补 0（1.0 == 1.0.0）。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func nums(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let r = nums(remote), l = nums(local)
        for i in 0 ..< max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - 检查

    /// 启动后的自动检查：默认开启（设置里可关），24 小时内最多一次，结果静默。
    func checkIfNeeded() async {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoUpdateCheck") as? Bool == false { return }
        if let last = defaults.object(forKey: "lastUpdateCheckAt") as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        defaults.set(Date(), forKey: "lastUpdateCheckAt")
        await check(manual: false)
    }

    /// 检查更新。manual = 用户点了「检查更新」按钮（失败/已最新都要明确反馈）；
    /// 自动检查时失败静默回到 idle，不打断用户。
    func check(manual: Bool) async {
        if case .checking = state { return }
        state = .checking
        do {
            var req = URLRequest(url: Self.apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("TokenUsage-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.network
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else { throw UpdateError.parse }
            if Self.isNewer(tag, than: currentVersion) {
                downloadURL = url
                availableVersion = tag
                state = .available(version: tag)
            } else {
                state = .upToDate(latest: tag)
            }
        } catch {
            state = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: - 下载并安装

    /// 下载最新 zip → 解压 → 替换当前 App → 自动重启。成功后本进程退出。
    func downloadAndInstall() async {
        guard case .available = state, let url = downloadURL else { return }
        state = .downloading
        do {
            let (tmpZip, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.network
            }
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("TokenUsageUpdate-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try runProcess("/usr/bin/ditto", ["-x", "-k", tmpZip.path, workDir.path])
            let newApp = workDir.appendingPathComponent("TokenUsage.app")
            guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.badPackage }
            state = .installing
            try swapAndRelaunch(newApp: newApp, workDir: workDir)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 生成「等本进程退出后替换并重启」的脚本，启动脚本后立即退出自身。
    private func swapAndRelaunch(newApp: URL, workDir: URL) throws {
        let target = Bundle.main.bundleURL
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target.path)"
        mv "\(newApp.path)" "\(target.path)"
        open "\(target.path)"
        rm -rf "\(workDir.path)"
        rm -f "$0"
        """
        let scriptURL = workDir.appendingPathComponent("update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()
        // 给脚本进程一点启动时间，再退出自身（脚本会等本进程消失后动手）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private func runProcess(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.installFailed }
    }

    enum UpdateError: LocalizedError {
        case network, parse, badPackage, installFailed

        var errorDescription: String? {
            switch self {
            case .network: return "网络请求失败，请稍后重试"
            case .parse: return "无法解析版本信息"
            case .badPackage: return "更新包内容异常"
            case .installFailed: return "更新安装失败"
            }
        }
    }
}
