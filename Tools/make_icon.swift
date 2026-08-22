import AppKit

// 生成 1024x1024 主图标：macOS 风格圆角矩形 + 蓝紫渐变 + 白色趋势线
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 24
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = (size - inset * 2) * 0.2237 // macOS 圆角比例

let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 蓝紫渐变背景（DeepSeek 蓝 -> Kimi 紫）
let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.56, green: 0.36, blue: 0.96, alpha: 1),
    ]
)!
gradient.draw(in: path, angle: -55)

// 轻微内阴影感的顶部高光
if let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.18),
    NSColor.white.withAlphaComponent(0),
]) {
    let hlRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    highlight.draw(in: NSBezierPath(roundedRect: hlRect, xRadius: radius, yRadius: radius), angle: 90)
}

// 白色趋势线（仪表盘 + 折线组合）
NSColor.white.withAlphaComponent(0.95).setStroke()
let line = NSBezierPath()
line.lineWidth = 46
line.lineCapStyle = .round
line.lineJoinStyle = .round
let pts: [NSPoint] = [
    NSPoint(x: 220, y: 300),
    NSPoint(x: 400, y: 430),
    NSPoint(x: 560, y: 380),
    NSPoint(x: 720, y: 560),
    NSPoint(x: 824, y: 640),
]
line.move(to: pts[0])
for p in pts.dropFirst() { line.line(to: p) }
line.stroke()

// 端点圆点
NSColor.white.setFill()
let dot = NSBezierPath(ovalIn: NSRect(x: 824 - 44, y: 640 - 44, width: 88, height: 88))
dot.fill()

// 底部三个小点（仪表盘刻度感）
NSColor.white.withAlphaComponent(0.55).setFill()
for i in 0..<3 {
    let x: CGFloat = 300 + CGFloat(i) * 190
    let d = NSBezierPath(ovalIn: NSRect(x: x - 20, y: 190, width: 40, height: 40))
    d.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon written:", CommandLine.arguments[1])
