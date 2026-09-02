import Foundation
import Metal
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SlideStoryModel

/// Ошибки работы с переходами.
public enum TransitionBlenderError: Error, LocalizedError, Sendable {
    case metalDeviceUnavailable
    case libraryLoadFailed(String)
    case kernelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal device is not available on this system."
        case .libraryLoadFailed(let reason):
            return "Failed to load the Metal transition library: \(reason)"
        case .kernelNotFound(let name):
            return "Metal kernel not found: \(name)"
        }
    }
}

/// Исполнитель переходов между слайдами.
///
/// - 7 простых переходов — встроенные фильтры Core Image;
/// - 5 кастомных — Metal-кернелы из `Transitions.metal`.
/// Кадры передаются в виде `CIImage`, текстуры для Metal создаются
/// лениво через `CIContext`.
public final class TransitionBlender: @unchecked Sendable {

    /// Текстуры для Metal-переходов.
    private struct Textures {
        let from: MTLTexture
        let to: MTLTexture
        let output: MTLTexture
    }

    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState
    private let kernelName: String
    private let ciContext: CIContext
    private let textureLoader: MTKTextureLoader
    private var commandQueue: MTLCommandQueue?

    /// - Parameter transitionType: тип перехода.
    /// - Throws: `TransitionBlenderError`.
    public init(transitionType: TransitionType) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TransitionBlenderError.metalDeviceUnavailable
        }
        self.device = device
        self.ciContext = CIContext(mtlDevice: device)
        self.textureLoader = MTKTextureLoader(device: device)

        // Загружаем библиотеку из бандла пакета.
        // ВАЖНО: НЕ используем `Bundle.module` напрямую — SPM генерирует его
        // с `fatalError` при недоступном ресурсном бандле (например, в .app,
        // собранном build_app.sh без ресурсов), что вызывает краш. Ищем бандл
        // по имени и при неудаче компилируем шейдер из встроенной строки.
        let library: MTLLibrary
        if let shaderBundle = Self.shaderBundle,
           let bundleLibrary = try? device.makeDefaultLibrary(bundle: shaderBundle) {
            library = bundleLibrary
        } else if let sourceLibrary = try? device.makeLibrary(source: Self.metalSource, options: nil) {
            library = sourceLibrary
        } else {
            // Диагностика причины, чтобы не терять реальную ошибку Metal.
            var loadError = "unknown"
            if let shaderBundle = Self.shaderBundle {
                if let err = try? device.makeDefaultLibrary(bundle: shaderBundle) { _ = err }
            }
            do {
                _ = try device.makeLibrary(source: Self.metalSource, options: nil)
            } catch {
                loadError = "\(error)"
            }
            throw TransitionBlenderError.libraryLoadFailed(loadError)
        }

        let name: String
        switch transitionType {
        case .door: name = "door"
        case .grid: name = "gridTransition"
        case .colorFade: name = "colorFade"
        default:
            // CI-переходы не требуют Metal-пиплайна.
            throw TransitionBlenderError.kernelNotFound("coreImage")
        }
        self.kernelName = name

        guard let kernel = library.makeFunction(name: name) else {
            throw TransitionBlenderError.kernelNotFound(name)
        }
        self.pipelineState = try device.makeComputePipelineState(function: kernel)
        self.commandQueue = device.makeCommandQueue()
    }


    /// Ищет ресурсный бандл с Metal-шейдерами безопасно, без `fatalError`
    /// из сгенерированного SPM `Bundle.module`.
    ///
    /// Имена бандлов: `Lumislide_SlideStoryRenderer.bundle` (в .app) или
    /// `SlideStoryRenderer_SlideStoryRenderer.bundle` (вариант Xcode/SPM).
    private static var shaderBundle: Bundle? {
        let candidates: [Bundle?] = [
            // В .app, собранном build_app.sh: бандл копируется в Contents/Resources.
            Bundle.main.url(forResource: "Lumislide_SlideStoryRenderer", withExtension: "bundle")
                .flatMap { Bundle(url: $0) },
            // Альтернативное имя, которое может генерировать SPM.
            Bundle.main.url(forResource: "SlideStoryRenderer_SlideStoryRenderer", withExtension: "bundle")
                .flatMap { Bundle(url: $0) },
            // В пакетном контексте (swift run / тесты) — ресурсы лежат рядом.
            Bundle.allBundles.first { $0.bundlePath.contains("SlideStoryRenderer") },
        ]
        return candidates.compactMap { $0 }.first
    }

    /// Смешивает два кадра с кастомным Metal-переходом.
    /// - Parameters:
    ///   - fromImage: исходный кадр.
    ///   - toImage: целевой кадр.
    ///   - progress: прогресс перехода (0...1).
    /// - Returns: смешанное изображение.
    public func blendMetal(fromImage: CIImage, toImage: CIImage, progress: Float) throws -> CIImage {
        let extent = fromImage.extent
        let textures = try makeTextures(from: fromImage, to: toImage, extent: extent)

        guard let commandQueue else {
            throw TransitionBlenderError.libraryLoadFailed("command queue unavailable")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw TransitionBlenderError.libraryLoadFailed("command buffer unavailable")
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(textures.from, index: 0)
        encoder.setTexture(textures.to, index: 1)
        encoder.setTexture(textures.output, index: 2)
        var clampedProgress = min(max(progress, 0), 1)
        encoder.setBytes(&clampedProgress, length: MemoryLayout<Float>.size, index: 0)

        // Используем dispatchThreads с фиксированным размером threadgroup:
        // размер группы 32×height превышает maxTotalThreadsPerThreadgroup (1024)
        // для реальных кадров и вызывает сбой Metal.
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadCount = MTLSize(
            width: textures.output.width,
            height: textures.output.height,
            depth: 1
        )
        encoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Metal-текстура читается Core Image вертикально перевёрнутой
        // (строка 0 текстуры соответствует верху, а CI считает её низом).
        // Возвращаем кадр в правильной ориентации.
        let rawOutput = CIImage(mtlTexture: textures.output, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()])
            ?? CIImage(cgImage: textures.output.toCGImage(ciContext: ciContext))
        return rawOutput.oriented(.downMirrored)
    }

    // MARK: - Metal-текстуры

    private func makeTextures(from: CIImage, to: CIImage, extent: CGRect) throws -> Textures {
        let width = max(Int(extent.width), 1)
        let height = max(Int(extent.height), 1)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let fromTex = try? textureLoader.newTexture(
            cgImage: ciContext.createCGImage(from, from: extent) ?? .emptyFallback(extent: extent)
        ),
        let toTex = try? textureLoader.newTexture(
            cgImage: ciContext.createCGImage(to, from: extent) ?? .emptyFallback(extent: extent)
        ),
        let outTex = device.makeTexture(descriptor: descriptor) else {
            throw TransitionBlenderError.libraryLoadFailed("texture creation failed")
        }

        return Textures(from: fromTex, to: toTex, output: outTex)
    }

    /// Реализация Metal-переходов через Core Image: применяет CI-фильтры
    /// для 7 «простых» переходов.
    public static func blendCoreImage(
        fromImage: CIImage,
        toImage: CIImage,
        transitionType: TransitionType,
        progress: Double
    ) -> CIImage? {
        switch transitionType {
        case .dissolve:
            return dissolve(from: fromImage, to: toImage, t: progress)
        case .slideLeft:
            return slide(from: fromImage, to: toImage, t: progress, direction: .left)
        case .slideRight:
            return slide(from: fromImage, to: toImage, t: progress, direction: .right)
        case .push:
            return push(from: fromImage, to: toImage, t: progress, direction: .left)
        case .pushRight:
            return push(from: fromImage, to: toImage, t: progress, direction: .right)
        case .irisOpen:
            return iris(from: fromImage, to: toImage, t: progress, open: true)
        case .irisClose:
            return iris(from: fromImage, to: toImage, t: progress, open: false)
        case .dipToBlack:
            return dipToBlack(from: fromImage, to: toImage, t: progress)
        default:
            return nil
        }
    }

    // MARK: - CI-переходы

    private enum SlideDirection { case left, right }

    private static func dissolve(from: CIImage, to: CIImage, t: Double) -> CIImage? {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = from
        filter.targetImage = to
        filter.time = Float(t)
        return filter.outputImage
    }

    private static func slide(from: CIImage, to: CIImage, t: Double, direction: SlideDirection) -> CIImage? {
        // Наиболее близкий CI-фильтр для «скольжения» — CISwipeTransition
        // с жёсткой маской (width = 0) и заданной ориентацией.
        let swipe = CIFilter.swipeTransition()
        swipe.inputImage = from
        swipe.targetImage = to
        swipe.time = Float(t)
        swipe.width = 0
        // Смещение: для скольжения влево маска движется слева направо,
        // для вправо — зеркально. В v1 — линейное движение через extent.
        swipe.angle = direction == .left ? 0 : .pi
        return swipe.outputImage
    }

    private static func push(from: CIImage, to: CIImage, t: Double, direction: SlideDirection) -> CIImage? {
        // CI не имеет push-перехода; используем комбинацию смещения:
        // два слоя, целевой «толкает» исходный.
        let width = from.extent.width
        let offset = CGFloat(t) * width * (direction == .left ? -1 : 1)

        let shiftedFrom = from.transformed(by: CGAffineTransform(translationX: offset, y: 0))
        let shiftedTo = to.transformed(by: CGAffineTransform(translationX: offset + (direction == .left ? width : -width), y: 0))
        let canvasRect = from.extent

        let composited = shiftedTo.composited(over: shiftedFrom)
        return composited.cropped(to: canvasRect)
    }

    /// Затемнение: cross-fade через чёрный (from → чёрный → to).
    private static func dipToBlack(from: CIImage, to: CIImage, t: Double) -> CIImage? {
        let extent = from.extent
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: extent)
        let scaled = min(max(t, 0), 1) * 2 // 0...2

        if scaled < 1 {
            let fade = CIFilter.dissolveTransition()
            fade.inputImage = from
            fade.targetImage = black
            fade.time = Float(min(scaled, 1))
            return fade.outputImage
        } else {
            let fade = CIFilter.dissolveTransition()
            fade.inputImage = black
            fade.targetImage = to
            fade.time = Float(min(scaled - 1, 1))
            return fade.outputImage
        }
    }

    /// Круг (iris). Оба варианта корректно начинаются с `from` и заканчиваются `to`:
    /// - open: круг `to` растёт из центра;
    /// - close: круг `from` сжимается к центру, открывая `to` с краёв.
    private static func iris(from: CIImage, to: CIImage, t: Double, open: Bool) -> CIImage? {
        let extent = from.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        // Полудиагональ: при t=1 круг гарантированно покрывает весь кадр.
        let maxRadius = hypot(extent.width, extent.height) / 2
        let radius = CGFloat(open ? t : (1.0 - t)) * maxRadius

        let radial = CIFilter.radialGradient()
        radial.center = center
        radial.radius0 = Float(max(radius, 0))
        radial.radius1 = Float(max(radius + 2, 2))
        if open {
            // Внутри круга — белый (to), снаружи — чёрный (from).
            radial.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            radial.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        } else {
            // Внутри сжимающегося круга — чёрный (from), снаружи — белый (to).
            radial.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            radial.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        guard let mask = radial.outputImage?.cropped(to: extent) else { return nil }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = to
        blend.backgroundImage = from
        blend.maskImage = mask
        return blend.outputImage
    }
}

import AppKit

private extension MTLTexture {
    /// Конвертирует текстуру в CGImage через CIContext (fallback).
    func toCGImage(ciContext: CIContext) -> CGImage {
        let image = CIImage(mtlTexture: self) ?? CIImage(color: .black).cropped(to: .init(x: 0, y: 0, width: 1, height: 1))
        return ciContext.createCGImage(image, from: image.extent) ??
            .emptyFallback(extent: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

private extension CGImage {
    /// Пустой прозрачный CGImage (fallback).
    static func emptyFallback(extent: CGRect) -> CGImage {
        let context = CGContext(
            data: nil,
            width: max(Int(extent.width), 1),
            height: max(Int(extent.height), 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

/// Исходный код Metal-шейдеров (fallback, если ресурс пакета не загрузился).
private extension TransitionBlender {
    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler s = sampler(coord::normalized, address::clamp_to_edge, filter::linear);

    kernel void door(
        texture2d<float, access::sample> from [[texture(0)]],
        texture2d<float, access::sample> to   [[texture(1)]],
        texture2d<float, access::write>  out  [[texture(2)]],
        constant float& progress [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        float2 uv = (float2(gid) + 0.5) / float2(from.get_width(), from.get_height());
        float t = clamp(progress, 0.0, 1.0);
        float halfVal = 0.5;
        float localX = uv.x;
        float mirrored = localX < halfVal ? localX / halfVal : (1.0 - localX) / halfVal;
        if (mirrored < t) { out.write(to.sample(s, uv), gid); return; }
        float2 src = uv;
        src.x = halfVal + (uv.x - halfVal) * (1.0 - t);
        out.write(from.sample(s, src), gid);
    }

    kernel void gridTransition(
        texture2d<float, access::sample> from [[texture(0)]],
        texture2d<float, access::sample> to   [[texture(1)]],
        texture2d<float, access::write>  out  [[texture(2)]],
        constant float& progress [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        float2 uv = (float2(gid) + 0.5) / float2(from.get_width(), from.get_height());
        float t = clamp(progress, 0.0, 1.0);
        float2 grid = float2(4.0, 3.0);
        float2 cell = floor(uv * grid);
        float cellID = cell.y * grid.x + cell.x;
        float order = fract(sin(cellID * 12.9898) * 43758.5453);
        float delay = order * 0.2;
        if (t < delay) { out.write(from.sample(s, uv), gid); return; }
        float2 cellUV = fract(uv * grid);
        float centerDist = length(cellUV - 0.5);
        float alpha = smoothstep(0.5, 0.0, centerDist) * clamp((t - delay) / 0.8, 0.0, 1.0);
        float4 a = from.sample(s, uv);
        float4 b = to.sample(s, uv);
        out.write(mix(a, b, alpha), gid);
    }

    kernel void colorFade(
        texture2d<float, access::sample> from [[texture(0)]],
        texture2d<float, access::sample> to   [[texture(1)]],
        texture2d<float, access::write>  out  [[texture(2)]],
        constant float& progress [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        float2 uv = (float2(gid) + 0.5) / float2(from.get_width(), from.get_height());
        float t = clamp(progress, 0.0, 1.0);
        float4 white = float4(1.0);
        float4 a = from.sample(s, uv);
        float4 b = to.sample(s, uv);
        float4 col;
        if (t < 0.5) { col = mix(a, white, t * 2.0); }
        else { col = mix(white, b, (t - 0.5) * 2.0); }
        out.write(col, gid);
    }
    """
}