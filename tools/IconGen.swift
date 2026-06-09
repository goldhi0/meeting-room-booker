import AppKit

// 1024x1024 앱 아이콘 PNG 생성: 토스블루 그라데이션 둥근사각 + 흰색 calendar.badge.plus
// 사용: icongen <출력경로.png>

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_master.png"

func bitmapRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

/// 흰색으로 칠한 SF Symbol 이미지(투명 배경) 생성.
func whiteSymbol(_ name: String, point: CGFloat) -> NSImage {
    let conf = NSImage.SymbolConfiguration(pointSize: point, weight: .semibold)
    let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(conf)!
    sym.isTemplate = true
    let sz = sym.size
    let rep = bitmapRep(Int(sz.width.rounded()), Int(sz.height.rounded()))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(origin: .zero, size: sz)
    sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: sz)
    out.addRepresentation(rep)
    return out
}

let rep = bitmapRep(Int(S), Int(S))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 둥근 사각 배경 (살짝 여백)
let inset: CGFloat = 84
let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = (S - 2 * inset) * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

NSGraphicsContext.saveGraphicsState()
path.addClip()
let grad = NSGradient(
    starting: NSColor(srgbRed: 0.31, green: 0.62, blue: 1.0, alpha: 1),   // 밝은 블루
    ending:   NSColor(srgbRed: 0.16, green: 0.42, blue: 0.93, alpha: 1)   // 토스 블루
)!
grad.draw(in: rect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 흰색 캘린더 심볼 중앙 배치
let symbol = whiteSymbol("calendar.badge.plus", point: 470)
let ss = symbol.size
let drawRect = NSRect(x: (S - ss.width) / 2, y: (S - ss.height) / 2 - 10, width: ss.width, height: ss.height)
symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 인코딩 실패\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("✅ \(outPath)")
