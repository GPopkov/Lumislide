import Foundation
import CoreImage
import SlideStoryModel

/// Конфигурация рендера кадра (разрешение холста).
public struct RenderFrameConfiguration: Sendable {
    /// Размер холста в пикселях (до масштабирования).
    public var canvasSize: CGSize
    /// Масштаб рендера (1.0 — полный, 0.5 — предпросмотр).
    public var renderScale: Double

    public init(canvasSize: CGSize, renderScale: Double = 1.0) {
        self.canvasSize = canvasSize
        self.renderScale = renderScale
    }
}

/// Ошибки рендера кадра.
public enum FrameRenderError: Error, LocalizedError, Sendable {
    case emptyTimeline

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return "Cannot render an empty timeline."
        }
    }
}

/// Рендерер кадра на произвольный момент шкалы.
///
/// Использует тот же пайплайн, что и экспорт: фото — `SlideImageCompositor`
/// (+Ken Burns), видео — `VideoFrameSource` + фоновая заливка (blur),
/// переходы — `TransitionBlender` (CI/Metal). Работает из любого потока.
public final class TimelineFrameRenderer: @unchecked Sendable {
    private let configuration: RenderFrameConfiguration
    /// Кэш источников кадров по индексу слайда.
    private var frameSources: [Int: SlideContextFactory.FrameSource] = [:]
    /// Кэш Metal-блендеров по имени кернела (ленивая инициализация).
    private var metalBlenders: [String: TransitionBlender] = [:]

    /// Инициализация рендерера.
    /// - Parameter configuration: конфигурация (разрешение/масштаб).
    public init(configuration: RenderFrameConfiguration) {
        self.configuration = configuration
    }

    /// Фиксирует проект: сбрасывает кэши источников кадров.
    public func invalidateCache() {
        frameSources.removeAll()
        metalBlenders.removeAll()
    }

    /// Рендерит кадр для момента времени.
    /// - Parameters:
    ///   - time: время в секундах на таймлайне итогового видео.
    ///   - timeline: таймлайн проекта.
    ///   - project: проект (для seed, настроек, титров, KB).
    /// - Returns: кадр (CIImage) в координатах холста.
    public func makeFrame(
        at time: Double,
        timeline: [SlideTimelineItem],
        project: SlideshowProject
    ) throws -> CIImage {
        guard let current = TimelineBuilder.slide(at: time, in: timeline) else {
            throw FrameRenderError.emptyTimeline
        }

        // Композит текущего слайда в его «локальное» время.
        let currentImage = try renderSlide(
            item: current.item,
            localTime: current.localTime,
            timeline: timeline,
            project: project
        )

        // Если время попадает в зону перехода после слайда и есть следующий —
        // смешиваем с кадром следующего слайда.
        let transitionDuration = current.item.transitionDuration
        let transition = current.item.transition
        guard transitionDuration > 0, let transition, current.item.slideIndex + 1 < timeline.count else {
            return currentImage
        }

        let transitionStart = current.item.endTime - transitionDuration
        guard time >= transitionStart else { return currentImage }

        let nextItem = timeline[current.item.slideIndex + 1]
        let nextLocalTime = (time - nextItem.startTime) / max(nextItem.duration, 0.001)
        let nextImage = try renderSlide(
            item: nextItem,
            localTime: nextLocalTime,
            timeline: timeline,
            project: project
        )

        let progress = (time - transitionStart) / transitionDuration

        // CI-переходы.
        if transition.backend == .coreImage {
            let blended = TransitionBlender.blendCoreImage(
                fromImage: currentImage,
                toImage: nextImage,
                transitionType: transition,
                progress: progress
            )
            if let blended {
                return blended.cropped(to: canvasRect())
            }
        }

        // Metal-переходы (ленивая инициализация блендера).
        let blender: TransitionBlender
        if let cached = metalBlenders[transition.rawValue] {
            blender = cached
        } else {
            let newBlender = try TransitionBlender(transitionType: transition)
            metalBlenders[transition.rawValue] = newBlender
            blender = newBlender
        }

        let result = try blender.blendMetal(
            fromImage: currentImage,
            toImage: nextImage,
            progress: Float(progress)
        )
        return result.cropped(to: canvasRect())
    }

    /// Масштабированный прямоугольник холста.
    private func canvasRect() -> CGRect {
        CGRect(
            origin: .zero,
            size: CGSize(
                width: configuration.canvasSize.width * configuration.renderScale,
                height: configuration.canvasSize.height * configuration.renderScale
            )
        )
    }

    // MARK: - Рендер одного слайда

    private func renderSlide(
        item: SlideTimelineItem,
        localTime: Double,
        timeline: [SlideTimelineItem],
        project: SlideshowProject
    ) throws -> CIImage {
        let slide = project.slides[item.slideIndex]
        let frameSource: SlideContextFactory.FrameSource
        if let cached = frameSources[item.slideIndex] {
            frameSource = cached
        } else {
            frameSource = try SlideContextFactory.makeFrameSource(
                reference: slide,
                cachedFrames: &frameSourcesByID
            )
            frameSources[item.slideIndex] = frameSource
        }

        switch frameSource {
        case .photo(let image):
            return renderPhoto(
                image: image,
                localTime: localTime,
                slideIndex: item.slideIndex,
                slide: slide,
                project: project
            )
        case .video(let videoSource):
            return try renderVideo(
                videoSource: videoSource,
                localTime: localTime,
                slide: slide
            )
        }
    }

    private var frameSourcesByID: [UUID: SlideContextFactory.FrameSource] = [:]

    private func renderPhoto(
        image: CIImage,
        localTime: Double,
        slideIndex: Int,
        slide: MediaReference,
        project: SlideshowProject
    ) -> CIImage {
        let isKBEnabled = project.isKenBurnsEnabled && !slide.isKenBurnsDisabled
        let trajectory: KenBurnsTrajectory?
        if isKBEnabled {
            // Лица учитываем только из актуального (upright) кэша детекции.
            let validFaces = (slide.faceRegionsEpoch == MediaReference.currentFaceRegionsEpoch)
                ? slide.faceRegions : []
            // Координаты лиц — в пространстве ИЗОБРАЖЕНИЯ; планировщик работает
            // в пространстве ХОЛСТА (с учётом aspect-fit полосы) — проецируем.
            let canvasFaces = Self.mapFacesToCanvas(
                validFaces,
                imageSize: image.extent.size,
                canvasSize: configuration.canvasSize
            )
            trajectory = KenBurnsPlanner.trajectory(
                seed: project.transitionSeedValue,
                slideIndex: slideIndex,
                duration: project.defaultPhotoDuration,
                faceRegions: canvasFaces
            )
        } else {
            trajectory = nil
        }

        let composited = SlideImageCompositor.composite(
            sourceImage: image,
            canvasSize: configuration.canvasSize,
            trajectory: trajectory,
            titleOverlay: slide.titleOverlay,
            renderScale: configuration.renderScale,
            progress: localTime
        )
        return composited.image
    }

    /// Проецирует координаты лиц из пространства изображения (top-left,
    /// upright, 0...1) в пространство холста с учётом aspect-fit полосы.
    /// Холст симметричен по вертикали — смещение по Y одинаково для top/bottom.
    static func mapFacesToCanvas(
        _ faces: [FaceRegion],
        imageSize: CGSize,
        canvasSize: CGSize
    ) -> [FaceRegion] {
        guard !faces.isEmpty,
              imageSize.width > 0, imageSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        let scale = min(canvasSize.width / imageSize.width,
                        canvasSize.height / imageSize.height)
        let fitW = imageSize.width * scale
        let fitH = imageSize.height * scale
        let offsetX = (canvasSize.width - fitW) / 2
        let offsetY = (canvasSize.height - fitH) / 2

        func mapX(_ x: Double) -> Double { Double((offsetX + x * fitW) / canvasSize.width) }
        func mapY(_ y: Double) -> Double { Double((offsetY + y * fitH) / canvasSize.height) }

        return faces.map { face in
            FaceRegion(
                x: mapX(face.x),
                y: mapY(face.y),
                width: Double(face.width * fitW / canvasSize.width),
                height: Double(face.height * fitH / canvasSize.height)
            )
        }
    }

    private func renderVideo(
        videoSource: VideoFrameSource,
        localTime: Double,
        slide: MediaReference
    ) throws -> CIImage {
        // Кадр видео в момент локального времени.
        let clampedLocal = min(max(localTime, 0), 1)
        let videoTime = clampedLocal * videoSource.duration
        let frame = try videoSource.frame(atTime: videoTime)

        // Компонируем как «фото» без Ken Burns: blur фон + fit передний план.
        let composited = SlideImageCompositor.composite(
            sourceImage: frame,
            canvasSize: configuration.canvasSize,
            trajectory: nil,
            titleOverlay: slide.titleOverlay,
            renderScale: configuration.renderScale
        )

        // Видео без Ken Burns, но с фоновой заливкой; титр — поверх.
        return composited.image
    }
}