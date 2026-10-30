// Secret Bot simgesini çizer: swift icon/make_icon.swift <çıktı.png>
// Lacivert→turkuaz zemin, beyaz kalkan, anahtar deliği ve yapay zekâ parıltısı.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Üstten aşağı koordinat (y aşağı doğru artar)
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// 1) Zemin: macOS simge ızgarası (824pt kare, 100pt kenar boşluğu)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1E1B4B)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x312E81), rgb(0x1D4ED8), rgb(0x0E9488)], [0, 0.55, 1]),
                       start: CGPoint(x: 180, y: 100), end: CGPoint(x: 844, y: 924), options: [])
// Üstte yumuşak ışık
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 360, y: 220), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 220), endRadius: 560, options: [])
ctx.restoreGState()

// 2) Kalkan
let cx: CGFloat = 512, top: CGFloat = 228, w: CGFloat = 440, h: CGFloat = 548
let shield = CGMutablePath()
shield.move(to: CGPoint(x: cx, y: top))
shield.addCurve(to: CGPoint(x: cx + w / 2, y: top + 70),
                control1: CGPoint(x: cx + 80, y: top + 52), control2: CGPoint(x: cx + 160, y: top + 70))
shield.addLine(to: CGPoint(x: cx + w / 2, y: top + h * 0.46))
shield.addCurve(to: CGPoint(x: cx, y: top + h),
                control1: CGPoint(x: cx + w / 2, y: top + h * 0.74), control2: CGPoint(x: cx + 110, y: top + h * 0.9))
shield.addCurve(to: CGPoint(x: cx - w / 2, y: top + h * 0.46),
                control1: CGPoint(x: cx - 110, y: top + h * 0.9), control2: CGPoint(x: cx - w / 2, y: top + h * 0.74))
shield.addLine(to: CGPoint(x: cx - w / 2, y: top + 70))
shield.addCurve(to: CGPoint(x: cx, y: top),
                control1: CGPoint(x: cx - 160, y: top + 70), control2: CGPoint(x: cx - 80, y: top + 52))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x0B1030, 0.45))
ctx.addPath(shield); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shield); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xE0E7FF)], [0, 1]),
                       start: CGPoint(x: cx, y: top), end: CGPoint(x: cx, y: top + h), options: [])
ctx.restoreGState()

// 3) Anahtar deliği (zemin renginde)
let hole = CGMutablePath()
let holeCY: CGFloat = top + 238, r: CGFloat = 66
hole.addEllipse(in: CGRect(x: cx - r, y: holeCY - r, width: 2 * r, height: 2 * r))
hole.move(to: CGPoint(x: cx - 30, y: holeCY + 30))
hole.addLine(to: CGPoint(x: cx + 30, y: holeCY + 30))
hole.addLine(to: CGPoint(x: cx + 46, y: holeCY + 178))
hole.addQuadCurve(to: CGPoint(x: cx + 30, y: holeCY + 194), control: CGPoint(x: cx + 48, y: holeCY + 194))
hole.addLine(to: CGPoint(x: cx - 30, y: holeCY + 194))
hole.addQuadCurve(to: CGPoint(x: cx - 46, y: holeCY + 178), control: CGPoint(x: cx - 48, y: holeCY + 194))
hole.closeSubpath()
ctx.saveGState()
ctx.addPath(hole); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x312E81), rgb(0x1D4ED8)], [0, 1]),
                       start: CGPoint(x: cx, y: holeCY - r), end: CGPoint(x: cx, y: holeCY + 194), options: [])
ctx.restoreGState()

// 4) Yapay zekâ parıltısı (4 köşeli yıldız) + küçük eşi
func sparkle(_ c: CGPoint, _ s: CGFloat, _ color: CGColor) {
    let p = CGMutablePath()
    let k: CGFloat = 0.18 // bel inceliği
    p.move(to: CGPoint(x: c.x, y: c.y - s))
    p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + s * k, y: c.y - s * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + s * k, y: c.y + s * k))
    p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - s * k, y: c.y + s * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - s * k, y: c.y - s * k))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.5, color: rgb(0xFDE68A, 0.8))
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
    ctx.restoreGState()
}
sparkle(CGPoint(x: 778, y: 252), 84, rgb(0xFDE68A))
sparkle(CGPoint(x: 852, y: 362), 36, rgb(0xFEF3C7))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("yazıldı: \(out)")
