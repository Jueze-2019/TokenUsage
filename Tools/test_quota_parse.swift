import Foundation

/// 离线验证 Kimi Code /usages 解析：读取真实响应 JSON，走 BalanceService 的解析逻辑。
@main
enum TestQuotaParse {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let quota = try BalanceService.parseKimiCodeQuota(data)
        print("membership: \(quota.membershipLevel) → \(quota.membershipTitle)")
        print("weekly: \(quota.weeklyUsed)/\(quota.weeklyLimit) 剩 \(quota.weeklyRemaining)  reset=\(quota.weeklyReset?.description ?? "nil")")
        print("window(\(quota.windowMinutes)min): \(quota.windowUsed)/\(quota.windowLimit) 剩 \(quota.windowRemaining)  reset=\(quota.windowReset?.description ?? "nil")")
        print("parallel: \(quota.parallelLimit)")
        print("booster: \(quota.boosterEnabled) monthlyUsedCents: \(quota.monthlyUsedCents)")
        assert(quota.weeklyLimit == 100 && quota.weeklyRemaining == quota.weeklyLimit - quota.weeklyUsed)
        assert(quota.windowMinutes == 300 && quota.weeklyReset != nil && quota.windowReset != nil)
        print("ASSERTIONS PASSED")
    }
}
