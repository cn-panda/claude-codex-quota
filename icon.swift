import Cocoa

// 生成 1024×1024 app 图标 PNG（深色圆角底 + 绿色油量表，与卡片呼应）
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let S = CGFloat(px)
// 圆角矩形底（留边距，符合 macOS 图标视觉）
let margin = S * 0.085
let rect = NSRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let grad = NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1),
                      ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1))!
grad.draw(in: bgPath, angle: -90)

// 油量表
let cx = S / 2, cy = S / 2 + S * 0.015
let rg = S * 0.255
let lw = S * 0.072
let startA: CGFloat = 225, total: CGFloat = 270
let frac: CGFloat = 0.72
let center = NSPoint(x: cx, y: cy)

let bg = NSBezierPath()
bg.appendArc(withCenter: center, radius: rg, startAngle: startA, endAngle: startA - total, clockwise: true)
bg.lineWidth = lw; bg.lineCapStyle = .round
NSColor(calibratedWhite: 1, alpha: 0.16).setStroke(); bg.stroke()

let fg = NSBezierPath()
fg.appendArc(withCenter: center, radius: rg, startAngle: startA, endAngle: startA - total * frac, clockwise: true)
fg.lineWidth = lw; fg.lineCapStyle = .round
NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.39, alpha: 1).setStroke(); fg.stroke()

let na = (startA - total * frac) * .pi / 180
let tip = NSPoint(x: cx + cos(na) * rg, y: cy + sin(na) * rg)
let needle = NSBezierPath()
needle.move(to: center); needle.line(to: tip)
needle.lineWidth = lw * 0.5; needle.lineCapStyle = .round
NSColor.white.setStroke(); needle.stroke()

let dotR = S * 0.034
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
