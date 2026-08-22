import Foundation
import SwiftUI

/// 支持的模型服务商。新增服务商时在此扩展，并实现 BalanceService 中对应的解析。
///
/// 三种取数形态：
/// - 余额制（DeepSeek / Kimi）：官方余额接口返回金额，消耗按快照差额推算
/// - 配额制（Kimi Code / GLM / MiniMax / Claude / Codex）：官方额度接口返回窗口用量百分比
/// - 自定义接口（小米 MiMo / 自定义模型）：用户在账户上填写查询地址，通用解析器识别常见字段
enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek
    case kimi
    case kimiCode
    case glm
    case minimax
    case claude
    case codex
    case mimo
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi · Moonshot"
        case .kimiCode: return "Kimi Code"
        case .glm: return "GLM · 智谱"
        case .minimax: return "MiniMax"
        case .claude: return "Claude"
        case .codex: return "Codex · OpenAI"
        case .mimo: return "小米 MiMo"
        case .custom: return "自定义模型"
        }
    }

    /// 是否为配额制（无金额余额，按周/滚动窗口限量或限次）
    var usesQuota: Bool {
        switch self {
        case .kimiCode, .glm, .minimax, .claude, .codex: return true
        case .deepseek, .kimi, .mimo, .custom: return false
        }
    }

    /// 是否需要用户在账户上自行填写查询接口地址（通用 JSON 解析）。
    /// 小米 MiMo 已由「官网登录同步」覆盖用量与余额，不再需要手动填接口。
    var usesCustomEndpoint: Bool {
        switch self {
        case .custom: return true
        default: return false
        }
    }

    /// 是否支持「登录官网后同步用量数据」（DeepSeek / 小米 MiMo 有控制台用量接口）
    var supportsWebSync: Bool {
        switch self {
        case .deepseek, .mimo: return true
        default: return false
        }
    }

    /// 官方余额查询接口（仅余额制服务商有）
    var balanceEndpoint: URL? {
        switch self {
        case .deepseek:
            return URL(string: "https://api.deepseek.com/user/balance")
        case .kimi:
            return URL(string: "https://api.moonshot.cn/v1/users/me/balance")
        default:
            return nil
        }
    }

    /// 官方额度查询接口（配额制服务商）
    var quotaEndpoint: URL? {
        switch self {
        case .kimiCode:
            return URL(string: "https://api.kimi.com/coding/v1/usages")
        case .glm:
            return URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        case .minimax:
            return URL(string: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")
        case .claude:
            return URL(string: "https://api.anthropic.com/api/oauth/usage")
        case .codex:
            return URL(string: "https://chatgpt.com/backend-api/wham/usage")
        default:
            return nil
        }
    }

    /// 开放平台控制台（用量页）；自定义模型无固定控制台
    var consoleURL: URL? {
        switch self {
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/usage")
        case .kimi:
            return URL(string: "https://platform.moonshot.cn/console/info")
        case .kimiCode:
            return URL(string: "https://www.kimi.com/code/console")
        case .glm:
            return URL(string: "https://open.bigmodel.cn/")
        case .minimax:
            return URL(string: "https://platform.minimaxi.com/subscribe/token-plan")
        case .claude:
            return URL(string: "https://claude.ai/settings/usage")
        case .codex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .mimo:
            return URL(string: "https://platform.xiaomimimo.com/token-plan")
        case .custom:
            return nil
        }
    }

    /// API Key / 凭证申请页面；自定义模型无固定页面
    var apiKeyURL: URL? {
        switch self {
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/api_keys")
        case .kimi:
            return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .kimiCode:
            return URL(string: "https://www.kimi.com/code/console")
        case .glm:
            return URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .minimax:
            return URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        case .claude:
            return URL(string: "https://claude.ai/settings")
        case .codex:
            return URL(string: "https://chatgpt.com/codex")
        case .mimo:
            return URL(string: "https://platform.xiaomimimo.com/token-plan")
        case .custom:
            return nil
        }
    }

    /// 设置页 / 向导中展示的凭证指引
    var credentialHint: String {
        switch self {
        case .deepseek:
            return "填写 DeepSeek 开放平台的 API Key（sk- 开头）。"
        case .kimi:
            return "填写 Moonshot 开放平台的 API Key（sk- 开头）。"
        case .kimiCode:
            return "填写 Kimi Code 会员的 API Key，用于查询订阅额度。"
        case .glm:
            return "填写智谱开放平台的 API Key，查询 Coding Plan 额度。"
        case .minimax:
            return "填写 MiniMax 开放平台的 API Key，查询 Coding Plan / Token Plan 额度。"
        case .claude:
            return "填写 Claude Code 登录凭证中的 accessToken（见 ~/.claude/.credentials.json），用于查询订阅用量。"
        case .codex:
            return "填写 Codex 登录凭证中的 access_token（见 ~/.codex/auth.json），用于查询订阅用量。"
        case .mimo:
            return "填写小米 MiMo 的 API Key。支持登录官网后同步用量（API 计费与 Token Plan 套餐），余额查询可填中转站提供的查询地址。"
        case .custom:
            return "填写任意返回 JSON 的余额/额度查询地址与对应 Key，自动识别 total_balance / available_balance / balance / utilization 等常见字段。"
        }
    }

    var accentColor: Color {
        switch self {
        case .deepseek: return Color(red: 0.29, green: 0.42, blue: 0.96) // DeepSeek 蓝
        case .kimi: return Color(red: 0.56, green: 0.36, blue: 0.96)     // Kimi 紫
        case .kimiCode: return Color(red: 0.10, green: 0.62, blue: 0.52) // Kimi Code 青绿
        case .glm: return Color(red: 0.16, green: 0.55, blue: 0.85)      // 智谱 天蓝
        case .minimax: return Color(red: 0.90, green: 0.25, blue: 0.40)  // MiniMax 品红
        case .claude: return Color(red: 0.82, green: 0.45, blue: 0.32)   // Claude 陶土橙
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.56)    // OpenAI 绿
        case .mimo: return Color(red: 1.00, green: 0.41, blue: 0.00)     // 小米橙
        case .custom: return Color(red: 0.50, green: 0.50, blue: 0.56)   // 自定义 灰
        }
    }
}

/// 各模型在用量图表中的颜色（稳定映射，不随启动变化）。
/// 对齐 DeepSeek 平台用量页：Flash = 橙，Pro = 蓝（原始名与短展示名都映射）。
/// 模型名在出图前已剥掉厂商前缀与版本段（v4/v5…），同家族升级（如 v5-pro → pro）
/// 自动继承固定配色；全新模型名走 djb2 稳定散列到调色板，模型数量/名称变化无需改代码。
enum ModelColors {
    private static let known: [String: Color] = [
        "deepseek-v4-flash": Color(red: 0.96, green: 0.52, blue: 0.04),
        "deepseek-v4-pro": Color(red: 0.29, green: 0.42, blue: 0.96),
        "flash": Color(red: 0.96, green: 0.52, blue: 0.04),
        "pro": Color(red: 0.29, green: 0.42, blue: 0.96),
        "kimi-k2-0711-preview": Color(red: 0.56, green: 0.36, blue: 0.96),
    ]
    /// 未知新模型的稳定配色池（12 色，尽量拉开色相，减少同图撞色）
    private static let palette: [Color] = [
        .teal, .pink, .green, .indigo, .mint, .brown,
        Color(red: 0.61, green: 0.35, blue: 0.94), // 紫
        Color(red: 0.20, green: 0.68, blue: 0.86), // 青蓝
        Color(red: 0.91, green: 0.30, blue: 0.45), // 品红
        Color(red: 0.55, green: 0.60, blue: 0.20), // 橄榄
        Color(red: 0.90, green: 0.60, blue: 0.30), // 杏
        Color(red: 0.45, green: 0.45, blue: 0.50), // 灰
    ]

    static func color(for model: String) -> Color {
        // 大小写兜底：上游模型名大小写变化时不丢固定配色
        if let color = known[model] ?? known[model.lowercased()] { return color }
        // djb2 稳定散列
        var hash: UInt64 = 5381
        for byte in model.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// token 类型（输入·命中 / 输入·未命中 / 输出）在用量图表与统计卡中的颜色。
enum TokenTypeColors {
    static func color(for type: String) -> Color {
        switch type {
        case UsageRecord.tokenTypeHit: return Color(red: 0.13, green: 0.70, blue: 0.67)  // 青（命中=省钱）
        case UsageRecord.tokenTypeMiss: return Color(red: 0.96, green: 0.52, blue: 0.04) // 橙
        default: return Color(red: 0.29, green: 0.42, blue: 0.96)                        // 蓝（输出）
        }
    }
}

/// 各 API Key 在用量图表中的颜色（按 Key 名稳定散列）。
enum KeyColors {
    private static let palette: [Color] = [
        Color(red: 0.29, green: 0.42, blue: 0.96), // DeepSeek 蓝
        Color(red: 0.13, green: 0.70, blue: 0.67), // 青
        Color(red: 0.96, green: 0.52, blue: 0.04), // 橙
        Color(red: 0.61, green: 0.35, blue: 0.94), // 紫
        Color(red: 0.91, green: 0.30, blue: 0.45), // 品红
        Color(red: 0.24, green: 0.66, blue: 0.33), // 绿
        .mint, .brown,
    ]

    static func color(for keyName: String) -> Color {
        // djb2 稳定散列
        var hash: UInt64 = 5381
        for byte in keyName.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
