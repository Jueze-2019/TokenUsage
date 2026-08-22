import Foundation

/// 数字展示格式化，主 App 与小组件共用。
enum Formatting {
    static func cny(_ value: Double, decimals: Int = 2) -> String {
        String(format: "¥%.\(decimals)f", value)
    }

    /// token 数格式化为易读形式：8,532 / 5.3 万 / 1.21 亿
    static func tokens(_ value: Double) -> String {
        switch value {
        case 100_000_000...:
            return String(format: "%.2f 亿", value / 100_000_000)
        case 10_000...:
            return String(format: "%.1f 万", value / 10_000)
        default:
            return String(format: "%.0f", value)
        }
    }

    /// 菜单栏紧凑显示：¥123 / ¥1.2w
    static func compactCNY(_ value: Double) -> String {
        if value >= 10_000 {
            return String(format: "¥%.1fw", value / 10_000)
        }
        return String(format: "¥%.0f", value)
    }

    /// 千分位整数字符串（如 5,049,409,353），对齐 DeepSeek 用量页的数字样式
    static func grouped(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 图表坐标轴用的大数缩写：1,200 / 900M / 1.8B（对齐 DeepSeek 图表刻度）
    static func axisTokens(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.0fM", value / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", value / 1_000)
        default:
            return String(format: "%.0f", value)
        }
    }
}
