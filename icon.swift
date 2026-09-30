import AppKit
// 최신 macOS 아이콘 격자: 1024 캔버스 안 824 모서리 둥근 사각형, 은은한 그라데이션·광택·그림자
let s = 1024.0
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)

// 바닥 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor(calibratedRed: 0.96, green: 0.45, blue: 0.22, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

// 주황 → 산호색 그라데이션
NSGradient(colors: [NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.33, alpha: 1),
                    NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.24, alpha: 1)])!
    .draw(in: shape, angle: -90)

// 위쪽 광택
ctx.saveGState()
shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
ctx.restoreGState()

// 안쪽 테두리 빛
NSColor.white.withAlphaComponent(0.18).setStroke()
let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
rim.lineWidth = 4
rim.stroke()

// 흰 지도 핀 + 부드러운 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.05, alpha: 0.45).cgColor)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .bold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    sym.draw(in: NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2 - 6, width: sym.size.width, height: sym.size.height))
}
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
