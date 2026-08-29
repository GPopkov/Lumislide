import AppKit

// ============================================================================
// Генерация иконки Lumislide (1024x1024, macOS Big Sur+ стиль).
// Фон: градиент indigo -> magenta -> pink + мягкое тёплое свечение.
// Мотив: белая «фото-карточка» с фотографией (небо/солнце/горы)
//        и круглой кнопкой play — слайдшоу из фото и видео.
// ============================================================================

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: S, height: S)

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
ctx.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// --- Базовый клип: скруглённый «квадрат» иконки ---
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// --- Фоновый градиент ---
let bgColors = [
    color(0.34, 0.21, 1.0),   // indigo
    color(0.63, 0.25, 1.0),   // violet
    color(1.0, 0.41, 0.56),   // pink
] as CFArray
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: 0, y: S),
                       end: CGPoint(x: S, y: 0),
                       options: [])

// --- Мягкое тёплое свечение («lumi») ---
let glowColors = [
    color(1.0, 0.86, 0.55, 0.30),
    color(1.0, 0.86, 0.55, 0.0),
] as CFArray
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: glowColors, locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: 330, y: 840), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 840), endRadius: 540,

                       options: [])

// --- Белая «фото-карточка» (лёгкий наклон) ---
let cardW: CGFloat = 660
let cardH: CGFloat = 500
let cardCenter = CGPoint(x: 512, y: 505)
let cardAngle: CGFloat = -0.04

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 60, color: color(0, 0, 0, 0.38))
ctx.translateBy(x: cardCenter.x, y: cardCenter.y)
ctx.rotate(by: cardAngle)
ctx.translateBy(x: -cardW / 2, y: -cardH / 2)
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: cardW, height: cardH),
                   cornerWidth: 60, cornerHeight: 60, transform: nil))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// --- «Фото» внутри карточки (в локальных координатах карточки) ---
ctx.saveGState()
ctx.translateBy(x: cardCenter.x, y: cardCenter.y)
ctx.rotate(by: cardAngle)
ctx.translateBy(x: -cardW / 2, y: -cardH / 2)
let photoRect = CGRect(x: 28, y: 28, width: cardW - 56, height: cardH - 56)
ctx.addPath(CGPath(roundedRect: photoRect, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.clip()

// небо: голубое сверху -> светлое снизу
let skyColors = [
    color(0.52, 0.79, 1.0),
    color(0.91, 0.97, 1.0),
] as CFArray
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: skyColors, locations: [0, 1])!
ctx.drawLinearGradient(sky,
                       start: CGPoint(x: 0, y: photoRect.maxY),
                       end: CGPoint(x: 0, y: photoRect.minY),
                       options: [])

// солнце (верхняя часть фото)
ctx.setFillColor(color(1.0, 0.82, 0.28))
ctx.fillEllipse(in: CGRect(x: photoRect.minX + 96, y: photoRect.maxY - 150,
                           width: 118, height: 118))

// дальняя гора (светлее)
ctx.setFillColor(color(0.74, 0.60, 1.0))
let backMountain = NSBezierPath()
backMountain.move(to: CGPoint(x: photoRect.minX, y: photoRect.minY))
backMountain.line(to: CGPoint(x: photoRect.minX + 240, y: photoRect.minY + 250))
backMountain.line(to: CGPoint(x: photoRect.minX + 460, y: photoRect.minY))
backMountain.close()
backMountain.fill()

// ближняя гора (темнее)
ctx.setFillColor(color(0.47, 0.32, 0.95))
let frontMountain = NSBezierPath()
frontMountain.move(to: CGPoint(x: photoRect.minX + 170, y: photoRect.minY))
frontMountain.line(to: CGPoint(x: photoRect.minX + 400, y: photoRect.minY + 285))
frontMountain.line(to: CGPoint(x: photoRect.maxX, y: photoRect.minY))
frontMountain.close()
frontMountain.fill()

ctx.restoreGState()

// --- Круглая кнопка play (белый круг + индиго-треугольник) ---
let badgeCenter = CGPoint(x: 512, y: 262)
let badgeR: CGFloat = 108

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.30))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR,
                           width: badgeR * 2, height: badgeR * 2))
ctx.restoreGState()

let triangle = NSBezierPath()
triangle.move(to: CGPoint(x: badgeCenter.x - 34, y: badgeCenter.y + 48))
triangle.line(to: CGPoint(x: badgeCenter.x - 34, y: badgeCenter.y - 48))
triangle.line(to: CGPoint(x: badgeCenter.x + 58, y: badgeCenter.y))
triangle.close()
ctx.setFillColor(color(0.37, 0.24, 0.95))
triangle.fill()

ctx.restoreGState() // базовый клип

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: "/tmp/lumi_icon_1024.png")
if let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: output)
    print("OK \(output.path)")
} else {
    print("FAILED: no PNG")
}

