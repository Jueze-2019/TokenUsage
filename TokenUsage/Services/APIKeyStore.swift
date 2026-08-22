import Foundation
import Security

/// API Key 的本地持久化。
///
/// 为什么不用 Keychain：本 App 的本机直装版是 ad-hoc 签名（无开发者 Team），
/// Keychain 条目按签名身份绑定——每次重新编译签名都会变化，旧条目随之
/// 无法删除/覆盖（SecItemDelete/SecItemAdd 静默失败），导致"删旧 Key、存新 Key"
/// 失效。改为 0600 权限的本地文件存储（与 ~/.ssh 私钥同一保护级别），
/// 对免签名构建完全可靠。
enum APIKeyStore {
    private static var storeURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenUsage", isDirectory: true)
            .appendingPathComponent("api_keys.json")
    }

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveAll(_ dict: [String: String]) {
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// 保存（覆盖）或删除（传空串）某个账户的 Key。
    static func save(key: String, for account: String) {
        var dict = loadAll()
        if key.isEmpty {
            dict.removeValue(forKey: account)
        } else {
            dict[account] = key
        }
        saveAll(dict)
    }

    static func read(for account: String) -> String? {
        loadAll()[account]
    }

    /// 清空所有已存 Key（恢复首次安装状态时调用）
    static func removeAll() {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: syncTokenStoreURL)
    }

    // MARK: - 官网同步登录态（userToken，按账户 ID 存放）

    private static var syncTokenStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenUsage", isDirectory: true)
            .appendingPathComponent("sync_tokens.json")
    }

    /// 保存（覆盖）或删除（传 nil / 空串）某账户的官网登录态
    static func saveSyncToken(_ token: String?, for accountID: UUID) {
        var dict: [String: String] = (try? Data(contentsOf: syncTokenStoreURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if let token, !token.isEmpty {
            dict[accountID.uuidString] = token
        } else {
            dict.removeValue(forKey: accountID.uuidString)
        }
        let url = syncTokenStoreURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func readSyncToken(for accountID: UUID) -> String? {
        guard let data = try? Data(contentsOf: syncTokenStoreURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict[accountID.uuidString]
    }
}

/// 旧版本（≤1.0）存在 Keychain 里的 Key，仅用于一次性迁移读取/清理。
enum LegacyKeychainReader {
    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tokenusage.apikeys",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 迁移完成后删除 Keychain 旧条目，防止删光 Key 后旧 Key 复活
    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
