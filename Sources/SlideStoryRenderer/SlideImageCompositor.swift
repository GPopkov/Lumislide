import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import SlideStoryModel

/// Результат композиции одного фото-слайда.
public struct CompositedSlide: Sendable {
    /// Итоговый кадр (CIImage) в координатах холста.
    public var image: CIImage
    /// Прямоугольник вписанного переднего плана в координатах холста.
    public var foregroundRect: CGRect
}

/// Сборка композита «фон (blur) + передний план (fit)» для одного слайда,
/// с последующим применением эффекта Кена Бёрнса единой трансформацией.
///
/// Реализация по ТЗ:
/// - изображение вписывается в холст целиком (`.fit`, letterbox/pillarbox)
///   без обрезки;
/// - пустое пространство заполняется размытой растянутой копией того же
///   изображения (instagram-style);
/// - Ken Burns применяется к результату целиком — передний план и фон
///   двигаются как единое целое.
public enum SlideImageCompositor {

    /// Собирает композит фото-слайда и применяет Ken Burns.
    /// - Parameters:
    ///   - sourceImage: исходное изображение (CIImage).
    ///   - canvasSize: размер холста в пикселях (до масштабирования).
    ///   - trajectory: траектория Ken Burns (nil — без движения).
    ///   - titleOverlay: титр поверх слайда (nil — нет).
    ///   - renderScale: масштаб рендера (1.0 — полное разрешение).
    ///   - progress: локальное время слайда (0...1) для интерполяции
    ///     траектории Ken Burns.
    /// - Returns: итоговый кадр.
    public static func composite(
        sourceImage: CIImage,
        canvasSize: CGSize,
        trajectory: KenBurnsTrajectory?,
        titleOverlay: TitleOverlay? = nil,
        renderScale: Double = 1.0,
        progress: Double = 0
    ) -> CompositedSlide {
        // ВАЖНО: canvasSize — это НЕ масштабированный размер; рендерер
        // передаёт исходный размер холста, а renderScale применяется здесь.
        // (Ранее renderer умножал size сам — возникало двойное масштабирование
        // в предпросмотре: холст уменьшался в 4 раза.)
        let canvas = CGSize(
            width: canvasSize.width * renderScale,
            height: canvasSize.height * renderScale
        )
        let canvasRect = CGRect(origin: .zero, size: canvas)

        // 1. Fit — вписываем изображение в холст.
        let fitRect = aspectFitRect(for: sourceImage.extent.size, in: canvasRect)

        // 2. Фон: размытая растянутая копия.
        let background = blurredBackground(from: sourceImage, canvasRect: canvasRect)

        // 3. Передний план (fit), поверх фона.
        let foreground = sourceImage.transformed(by: transform(from: fitRect, to: sourceImage.extent))

        // В CIImage наложение: foreground поверх background.
        let layered = foreground.composited(over: background)

        // 4. Ken Burns — единая трансформация всего кадра.
        let final: CIImage
        if let trajectory {
            let t = trajectoryRectForTime(trajectory, canvasRect: canvasRect, progress: progress)
            let scaleX = canvasRect.width / t.width
            let scaleY = canvasRect.height / t.height
            let transform = CGAffineTransform(
                translationX: -t.minX * scaleX,
                y: -t.minY * scaleY
            )
            .scaledBy(x: scaleX, y: scaleY)
            let transformed = layered.transformed(by: transform)
            final = cropToCanvas(transformed, canvasRect: canvasRect)
        } else {
            final = layered
        }

        // 5. Титр.
        let titled: CIImage = titleOverlay.map { overlay in
            addTitle(overlay, to: final, canvas: canvasRect)
        } ?? final

        return CompositedSlide(image: titled, foregroundRect: fitRect)
    }

    /// Прямоугольник вписывания (aspect fit).
    public static func aspectFitRect(for sourceSize: CGSize, in canvasRect: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let scaleX = canvasRect.width / sourceSize.width
        let scaleY = canvasRect.height / sourceSize.height
        let scale = min(scaleX, scaleY)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return CGRect(
            x: canvasRect.midX - width / 2,
            y: canvasRect.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Private

    /// Размытая растянутая копия изображения на весь холст.
    private static func blurredBackground(from image: CIImage, canvasRect: CGRect) -> CIImage {
        // Растягиваем изображение на весь холст (искажение пропорций).
        let stretchTransform = CGAffineTransform(
            a: canvasRect.width / max(image.extent.width, 1),
            b: 0,
            c: 0,
            d: canvasRect.height / max(image.extent.height, 1),
            tx: canvasRect.minX,
            ty: canvasRect.minY
        )
        let stretched = image.transformed(by: stretchTransform)

        // Blur + лёгкое затемнение для контраста с передним планом.
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = stretched
        blurFilter.radius = Float(max(canvasRect.width, canvasRect.height) / 60)

        guard let blurred = blurFilter.outputImage else { return stretched }

        // Жёсткая обрезка, чтобы blur не вылезал за края.
        return blurred.cropped(to: canvasRect)
    }

    /// Трансформация из прямоугольника назначения обратно в исходные
    /// координаты изображения (для `transformed(by:)`).
    private static func transform(from sourceRect: CGRect, to targetRect: CGRect) -> CGAffineTransform {
        // CIImage.transformed(by:) использует координаты с origin внизу-слева.
        // Вычисляем аффинное преобразование, переводящее targetRect в sourceRect.
        let scaleX = sourceRect.width / max(targetRect.width, 1)
        let scaleY = sourceRect.height / max(targetRect.height, 1)
        return CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scaleY,
            tx: sourceRect.minX - targetRect.minX * scaleX,
            ty: sourceRect.minY - targetRect.minY * scaleY
        )
    }

    /// Прямоугольник Ken Burns в пиксельных координатах холста,
    /// интерполированный на момент времени слайда (0...1).
    ///
    /// Траектория задана в нормализованных координатах с origin ВВЕРХУ-СЛЕВА,
    /// а CIImage использует origin ВНИЗУ-СЛЕВА — инвертируем Y.
    private static func trajectoryRectForTime(_ trajectory: KenBurnsTrajectory, canvasRect: CGRect, progress: Double) -> CGRect {
        let clamped = min(max(progress, 0), 1)
        let normalized = trajectory.rect(atTime: clamped)
        return CGRect(
            x: normalized.origin.x * canvasRect.width,
            y: (1.0 - normalized.maxY) * canvasRect.height,
            width: normalized.width * canvasRect.width,
            height: normalized.height * canvasRect.height
        )
    }

    private static func cropToCanvas(_ image: CIImage, canvasRect: CGRect) -> CIImage {
        image.cropped(to: canvasRect)
    }

    /// Рисует титр через Core Graphics и накладывает на кадр.
    private static func addTitle(_ overlay: TitleOverlay, to image: CIImage, canvas: CGRect) -> CIImage {
        let size = canvas.size
        guard size.width > 0, size.height > 0 else { return image }

        let renderer = ImageRenderer(size: size)
        let titleRect = textRect(
            text: overlay.text,
            fontSize: overlay.fontSize * (size.height / 1080.0),
            position: overlay.position,
            canvas: canvas
        )

        renderer.drawText(
            text: overlay.text,
            in: titleRect,
            fontSize: overlay.fontSize * (size.height / 1080.0),
            color: overlay.cgColor
        )

        guard let textImage = renderer.image else { return image }
        return CIImage(cgImage: textImage).composited(over: image)
    }

    private static func textRect(text: String, fontSize: CGFloat, position: TitlePosition, canvas: CGRect) -> CGRect {
        // Оценка размера текста.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        let bounding = text.boundingRect(
            with: CGSize(width: canvas.width * 0.9, height: canvas.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        let centerX = canvas.midX - bounding.width / 2
        let y: CGFloat
        switch position {
        case .top:
            y = canvas.height * 0.12 - bounding.height / 2
        case .center:
            y = canvas.midY - bounding.height / 2
        case .bottom:
            y = canvas.height * 0.88 - bounding.height / 2
        }
        return CGRect(x: centerX, y: y, width: bounding.width, height: bounding.height)
    }
}

import AppKit

/// Мини-рендерер текста в CGImage (Core Graphics).
fileprivate final class ImageRenderer {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(size: CGSize) {
        self.size = size
    }

    var image: CGImage? {
        guard let block = drawBlock else { return nil }
        return draw(block)
    }

    private var drawBlock: ((CGContext) -> Void)?

    func drawText(text: String, in rect: CGRect, fontSize: CGFloat, color: CGColor) {
        drawBlock = { [weak self] context in
            guard let self else { return }
            context.saveGState()
            // Координаты Core Graphics: origin внизу-слева; наш titleRect
            // в координатах с origin вверху-слева — инвертируем по Y.
            let flipped = CGRect(
                x: rect.minX,
                y: self.size.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(cgColor: color) ?? .white,
                .paragraphStyle: paragraph,
            ]
            (text as NSString).draw(in: flipped, withAttributes: attributes)
            context.restoreGState()
        }
    }

    private func draw(_ block: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Прозрачный фон.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.textMatrix = .identity

        // NSString.draw требует активного NSGraphicsContext: без него
        // отрисовка текста в голом CGContext ведёт себя неопределённо.
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        let savedContext = NSGraphicsContext.current
        NSGraphicsContext.current = graphicsContext
        block(context)
        NSGraphicsContext.current = savedContext

        return context.makeImage()
    }
}