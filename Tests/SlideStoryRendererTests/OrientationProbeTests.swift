import XCTest
import Foundation
import CoreGraphics
import CoreImage
import AppKit
@testable import SlideStoryRenderer
@testable import SlideStoryModel

/// Регрессия: Metal-переходы (дверь, сетка, вспышка) не должны переворачивать
/// кадр вверх ногами (текстура из Metal читается Core Image перевёрнутой).
final class MetalTransitionOrientationTests: XCTestCase {

    /// Создаёт CIImage: верхняя половина — красная, нижняя — синяя.
    private func makeRedTopBlueBottom(w: Int = 128, h: Int = 128) -> CIImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)) // синий низ
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)) // красный верх
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Проверяет, что в верхней части кадра красный, в нижней — синий (не перевёрнут).
    /// - Parameter x: колонка для проверки (для «Двери» исходный кадр на раннем
    ///   progress виден у краёв, т.к. дверь открывается от центра).
    private func isUpright(_ image: CIImage, atX x: Int = 8) -> Bool {
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(image, from: image.extent) else { return false }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let g = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
                          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { // y=0 — верх
            let i = (y * cg.width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let top = px(x, 4)
        let bottom = px(x, cg.height - 5)
        return top.0 > top.2 && bottom.2 > bottom.0
    }

    func testMetalTransitionsDoNotFlipFrame() throws {
        let from = makeRedTopBlueBottom()
        let to = CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.2)).cropped(to: from.extent)

        for type in [TransitionType.door, .grid, .colorFade] {
            let blender = try TransitionBlender(transitionType: type)
            // На progress ~0 виден в основном исходный кадр.
            let early = try blender.blendMetal(fromImage: from, toImage: to, progress: 0.05)
            XCTAssertTrue(isUpright(early), "\(type.rawValue) переворачивает кадр на раннем progress")
            // На progress ~1 виден в основном целевой кадр (однотонный — проверяем размер).
            let late = try blender.blendMetal(fromImage: from, toImage: to, progress: 0.98)
            XCTAssertGreaterThan(late.extent.width, 0)
        }
    }
}

