import Foundation

/// 一次性工具：把 DeepSeek 用量导出 ZIP 重新导入到共享缓存，
/// 挂在 DeepSeek 默认账户下（保留已有的 keys / dataByKey）。
/// 用法: import_restore <zip路径>
@main
enum ImportRestore {
    static func main() {
        let group = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.tokenusage.shared", isDirectory: true)
        let cacheURL = group.appendingPathComponent("balance_cache.json")

        guard CommandLine.arguments.count > 1 else {
            print("usage: import_restore <zip>")
            exit(1)
        }
        let zipURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let result = try UsageImporter.importZIP(at: zipURL)
            var records = result.records
            print("解析到 \(records.count) 条记录，覆盖截止 \(result.coverageEnd)")

            var cache: SharedCache
            if let data = try? Data(contentsOf: cacheURL),
               let existing = try? decoder.decode(SharedCache.self, from: data) {
                cache = existing
            } else {
                cache = SharedCache()
            }

            guard let accountID = cache.keys.first(where: { $0.provider == .deepseek })?.accountID else {
                print("缓存中没有 DeepSeek Key，无法确定账户")
                exit(2)
            }
            print("目标账户: \(accountID.uuidString)")

            for i in records.indices { records[i].accountID = accountID }
            cache.usageRecords.removeAll { $0.accountID == accountID }
            cache.usageRecords.append(contentsOf: records)
            cache.usageRecords.sort { $0.day < $1.day }
            cache.usageCoverageEnd[accountID.uuidString] = result.coverageEnd
            cache.updatedAt = Date()

            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            print("已写入 \(records.count) 条记录到共享缓存")
        } catch {
            print("失败: \(error.localizedDescription)")
            exit(3)
        }
    }
}
