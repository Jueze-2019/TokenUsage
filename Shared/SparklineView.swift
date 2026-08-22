import SwiftUI

/// 轻量折线 + 面积图，主 App 与小组件共用（无 Charts 依赖，Widget 里更稳）。
struct SparklineView: View {
    let values: [Double]
    var lineColor: Color = .accentColor
    var fillOpacity: Double = 0.18

    var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(in: geo.size)
            if points.count > 1 {
                areaPath(points: points, in: geo.size)
                    .fill(lineColor.gradient.opacity(fillOpacity))
                linePath(points: points)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                // 数据不足时画一条虚线基线
                Path { path in
                    let y = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(lineColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard let minValue = values.min(), let maxValue = values.max(), values.count > 1 else {
            return []
        }
        let range = (maxValue - minValue) == 0 ? 1 : (maxValue - minValue)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let rawY = size.height * (1 - CGFloat((value - minValue) / range))
            let y = Swift.min(Swift.max(rawY, 1), size.height - 1)
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { $0.addLines(points) }
    }

    private func areaPath(points: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            path.addLines(points)
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}
