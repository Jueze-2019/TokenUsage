import Foundation

/// 负责主 App 与小组件之间的数据共享。
/// 首选 App Group 容器；若签名未配置 App Group（返回 nil），主 App 退回到
/// ~/Library/Application Support/TokenUsage，此时小组件读不到数据，仅显示占位。
enum SharedStore {
    static let appGroupID = "group.com.tokenusage.shared"
    static let cacheFileName = "balance_cache.json"

    static var containerURL: URL? {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return groupURL
        }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TokenUsage", isDirectory: true)
    }

    static var cacheURL: URL? {
        containerURL?.appendingPathComponent(cacheFileName)
    }

    static func write(_ cache: SharedCache) {
        guard let url = cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> SharedCache? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedCache.self, from: data)
    }

    /// 读取旧版（单 Key）格式缓存，用于一次性迁移。
    static func readLegacy() -> LegacySharedCache? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LegacySharedCache.self, from: data)
    }
}
