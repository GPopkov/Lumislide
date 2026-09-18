import Foundation
import CoreImage
import SlideStoryModel

/// Конфигурация рендера кадра (разрешение холста).
public struct RenderFrameConfiguration: Sendable {
    /// Размер холста в пикселях (до масштабирования).
    public var canvasSize: CGSize
    /// Масштаб рендера (1.0 — полный, 0.5 — предпросмотр).
    public var renderScale: Double
    /// Предел длинной стороны декодируемых источников (фото/видео), px.
    /// nil — вычисляется из холста с запасом на Ken Burns.
    /// Ограничение критично для памяти: полноразмерные фото/видео 4K+ дают
    /// десятки мегабайт на слайд.
    public var sourceMaxPixelSize: CGFloat?
    /// Предел числа кэшируемых источников кадров (LRU).
    public var maxCachedSources: Int
    /// Предел числа кэшируемых «баз» фото-слайдов (blur + fit), LRU.
    public var maxCachedPhotoBases: Int

    public init(
        canvasSize: CGSize,
        renderScale: Double = 1.0,
        sourceMaxPixelSize: CGFloat? = nil,
        maxCachedSources: Int = 6,
        maxCachedPhotoBases: Int = 4
    ) {
        self.canvasSize = canvasSize
        self.renderScale = renderScale
        self.sourceMaxPixelSize = sourceMaxPixelSize
        self.maxCachedSources = maxCachedSources
        self.maxCachedPhotoBases = maxCachedPhotoBases
    }

    /// Эффективный предел декодирования источников (px).
    public var effectiveSourceMaxPixelSize: CGFloat {
        if let sourceMaxPixelSize { return sourceMaxPixelSize }
        let side = max(canvasSize.width, canvasSize.height) * renderScale
        // Запас на Ken Burns (зум до ~1.3x) и заливку фона.
        return (side * 1.4).rounded(.up)
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
    /// Кэш источников кадров по индексу слайда (с LRU-ограничением).
    private var frameSources: [Int: SlideContextFactory.FrameSource] = [:]
    /// Порядок использования источников (LRU: последний — самый свежий).
    private var sourceOrder: [Int] = []
    /// Кэш «баз» фото-слайдов (blur + fit без Ken Burns/титра).
    /// Baked photo base: canvas-sized bitmap + size of the original image
    /// (needed to project face regions for Ken Burns).
    private struct PhotoBaseEntry {
        let image: CIImage
        let sourceSize: CGSize
    }

    private var photoBases: [Int: PhotoBaseEntry] = [:]
    private var photoBaseOrder: [Int] = []
    /// Кэш отрисованных титров по индексу слайда.
    private var titleImages: [Int: CGImage] = [:]
    private var titleOrder: [Int] = []
    /// Кэш Metal-блендеров по имени кернела (ленивая инициализация).
    private var metalBlenders: [String: TransitionBlender] = [:]
    /// Контекст для «запекания» базы фото-слайда в растр (см. photoBase).
    private let rasterContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Инициализация рендерера.
    /// - Parameter configuration: конфигурация (разрешение/масштаб).
    public init(configuration: RenderFrameConfiguration) {
        self.configuration = configuration
    }

    /// Фиксирует проект: сбрасывает кэши источников кадров.
    public func invalidateCache() {
        frameSources.removeAll()
        sourceOrder.removeAll()
        photoBases.removeAll()
        photoBaseOrder.removeAll()
        titleImages.removeAll()
        titleOrder.removeAll()
        metalBlenders.removeAll()
    }

    /// Размеры внутренних кэшей (для тестов/диагностики): число источников,
    /// запечённых баз фото и титров. Должны быть ограничены конфигурацией.
    public var cacheCounts: (sources: Int, photoBases: Int, titleImages: Int) {
        (frameSources.count, photoBases.count, titleImages.count)
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

        // Photo: if the baked base is cached, the source file is not needed at
        // all (otherwise the source was re-created on every frame and kept in
        // memory forever).
        if slide.kind == .photo, let cached = photoBases[item.slideIndex] {
            touchBase(item.slideIndex)
            return renderPhoto(
                base: cached.image,
                sourceSize: cached.sourceSize,
                localTime: localTime,
                slideIndex: item.slideIndex,
                slide: slide,
                project: project
            )
        }

        let frameSource = try frameSource(for: slide, slideIndex: item.slideIndex)

        switch frameSource {
        case .photo(let image):
            return renderPhoto(
                base: photoBase(image: image, slideIndex: item.slideIndex).image,
                sourceSize: image.extent.size,
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

    // MARK: - Кэши источников/баз/титров (с ограничением по памяти)

    /// Источник кадров слайда: из кэша или создаём (с ограничением декодирования).
    private func frameSource(for slide: MediaReference, slideIndex: Int) throws -> SlideContextFactory.FrameSource {
        if let cached = frameSources[slideIndex] {
            touchSource(slideIndex)
            return cached
        }
        var scratch: [UUID: SlideContextFactory.FrameSource] = [:]
        let source = try SlideContextFactory.makeFrameSource(
            reference: slide,
            cachedFrames: &scratch,
            maxPixelSize: configuration.effectiveSourceMaxPixelSize
        )
        frameSources[slideIndex] = source
        touchSource(slideIndex)
        return source
    }

    private func touchSource(_ index: Int) {
        if let existing = sourceOrder.firstIndex(of: index) {
            sourceOrder.remove(at: existing)
        }
        sourceOrder.append(index)
        // Освобождаем самые старые источники (вместе с производными кэшами).
        while sourceOrder.count > max(configuration.maxCachedSources, 2) {
            let old = sourceOrder.removeFirst()
            frameSources.removeValue(forKey: old)
            photoBases.removeValue(forKey: old)
            photoBaseOrder.removeAll { $0 == old }
            titleImages.removeValue(forKey: old)
            titleOrder.removeAll { $0 == old }
        }
    }

    /// «База» фото-слайда (blur + fit) — считается один раз на слайд.
    /// Marks the baked base as recently used (LRU).
    private func touchBase(_ slideIndex: Int) {
        if let existing = photoBaseOrder.firstIndex(of: slideIndex) {
            photoBaseOrder.remove(at: existing)
        }
        photoBaseOrder.append(slideIndex)
    }

    private func photoBase(image: CIImage, slideIndex: Int) -> PhotoBaseEntry {
        if let cached = photoBases[slideIndex] {
            touchBase(slideIndex)
            return cached
        }
        let computed = SlideImageCompositor.makeBase(
            sourceImage: image,
            canvasSize: configuration.canvasSize,
            renderScale: configuration.renderScale
        ).image
        // «Запекаем» базу в растр размером холста: иначе кэш хранит граф
        // CIImage со ссылкой на крупный исходник (десятки МБ на 24-60 МП
        // фото), и память экспорта растёт до гигабайтов. После запекания
        // исходник больше не нужен — освобождаем его.
        let base: CIImage
        if let cg = rasterContext.createCGImage(computed, from: computed.extent) {
            base = CIImage(cgImage: cg)
            frameSources.removeValue(forKey: slideIndex)
            sourceOrder.removeAll { $0 == slideIndex }
            // Запекание разово на слайд: чистим кэш контекста, иначе он
            // накапливает текстуры всех исходников (десятки МБ на фото).
            rasterContext.clearCaches()
        } else {
            base = computed
        }
        let entry = PhotoBaseEntry(image: base, sourceSize: image.extent.size)
        photoBases[slideIndex] = entry
        photoBaseOrder.append(slideIndex)
        while photoBaseOrder.count > max(configuration.maxCachedPhotoBases, 2) {
            let old = photoBaseOrder.removeFirst()
            photoBases.removeValue(forKey: old)
        }
        return entry
    }

    /// Отрисованный титр слайда (кэшируется; перерисовка текста на каждом
    /// кадре — заметная трата времени).
    private func titleImage(for slide: MediaReference, slideIndex: Int) -> CGImage? {
        guard let overlay = slide.titleOverlay else { return nil }
        if let cached = titleImages[slideIndex] { return cached }
        guard let image = SlideImageCompositor.makeTitleImage(
            overlay,
            canvasSize: configuration.canvasSize,
            renderScale: configuration.renderScale
        ) else { return nil }
        titleImages[slideIndex] = image
        titleOrder.append(slideIndex)
        while titleOrder.count > 2 {
            let old = titleOrder.removeFirst()
            titleImages.removeValue(forKey: old)
        }
        return image
    }

    private func renderPhoto(
        base: CIImage,
        sourceSize: CGSize,
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
                imageSize: sourceSize,
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

        return SlideImageCompositor.composite(
            base: base,
            canvasSize: configuration.canvasSize,
            trajectory: trajectory,
            titleImage: titleImage(for: slide, slideIndex: slideIndex),
            renderScale: configuration.renderScale,
            progress: localTime
        )
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
        let frame: CIImage
        do {
            frame = try videoSource.frame(atTime: videoTime)
        } catch {
            // Не валим весь экспорт из-за одного недоступного кадра:
            // рендерим чёрный кадр и продолжаем. Диагностика — в stderr.
            FileHandle.standardError.write(
                Data("Lumislide: video frame unavailable \(error.localizedDescription)\n".utf8)
            )
            frame = CIImage(color: CIColor.black).cropped(
                to: CGRect(origin: .zero, size: configuration.canvasSize)
            )
        }

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