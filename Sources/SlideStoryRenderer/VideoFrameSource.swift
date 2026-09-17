import Foundation
import AVFoundation
import CoreImage
import ImageIO
import SlideStoryModel

/// Ошибки работы с видео-источниками.
public enum VideoFrameSourceError: Error, LocalizedError, Sendable {
    case cannotOpenAsset(String)
    case noVideoTrack
    case invalidFrameTime

    public var errorDescription: String? {
        switch self {
        case .cannotOpenAsset(let name):
            return "Cannot open video asset: \(name)."
        case .noVideoTrack:
            return "The video file has no video track."
        case .invalidFrameTime:
            return "Invalid frame time."
        }
    }
}

/// Источник кадров видео-слайда.
///
/// В v1 извлечение кадров через `AVAssetImageGenerator` с повторным
/// seek на каждый кадр (см. «известные ограничения» в ТЗ, раздел 14).
/// При необходимости заменяется последовательным чтением через
/// `AVAssetReader`.
public final class VideoFrameSource: @unchecked Sendable {
    private let asset: AVAsset
    /// Точный генератор (нулевой допуск).
    private let generator: AVAssetImageGenerator
    /// Генератор «в точке или сразу после» — для файлов, где нет кадра
    /// ровно в запрошенный момент (смещённый первый кадр, edit list).
    private let tolerantGenerator: AVAssetImageGenerator
    /// Генератор «любой ближайший кадр» (допуск бесконечный).
    private let anyGenerator: AVAssetImageGenerator
    private let assetDuration: Double
    /// Начало диапазона видеодорожки (может быть не 0).
    private let trackStart: Double
    /// Конец диапазона видеодорожки (сек).
    private let trackEnd: Double
    private let videoSize: CGSize
    /// Удерживает security-scoped доступ к файлу на всё время жизни
    /// источника (иначе доступ закроется сразу после резолвинга).
    private let accessHolder: SecurityScopedAccess?
    private let fileName: String
    /// Последний успешно извлечённый кадр (запасной вариант, чтобы один
    /// «плохой» кадр не прерывал рендер).
    private var lastGoodFrame: CIImage?
    private let lock = NSLock()

    /// Инициализирует источник кадров для файла.
    /// - Parameters:
    ///   - url: URL видеофайла.
    ///   - accessHolder: держатель security-scoped доступа (удерживается).
    /// - Throws: `VideoFrameSourceError`.
    public init(url: URL, accessHolder: SecurityScopedAccess? = nil) throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        self.accessHolder = accessHolder
        self.fileName = url.lastPathComponent

        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoFrameSourceError.noVideoTrack
        }

        func makeGenerator(_ before: CMTime, _ after: CMTime) -> AVAssetImageGenerator {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = before
            g.requestedTimeToleranceAfter = after
            return g
        }
        self.generator = makeGenerator(.zero, .zero)
        self.tolerantGenerator = makeGenerator(.zero, CMTime(seconds: 0.5, preferredTimescale: 600))
        self.anyGenerator = makeGenerator(.positiveInfinity, .positiveInfinity)

        // ВАЖНО: контейнерная длительность может быть больше реального
        // диапазона видеодорожки — у многих файлов (запись экрана, mux с более
        // длинным аудио) `asset.duration` задаётся самой длинной дорожкой,
        // а кадров в «хвосте» нет. Дополнительно учитываем СМЕЩЕНИЕ начала
        // дорожки (`timeRange.start`): у части файлов (edit list, склейки)
        // первый кадр не в нуле, и запрос кадра в 0 падал
        // («Cannot open video asset: frame at 0.0s»).
        let containerDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        let rangeStart = track.timeRange.start.seconds
        let rangeDuration = track.timeRange.duration.seconds
        let rangeStartSafe = rangeStart.isFinite ? max(rangeStart, 0) : 0
        let rangeEnd = (rangeStart.isFinite && rangeDuration.isFinite)
            ? rangeStart + rangeDuration
            : containerDuration
        let trackEndRaw = max(rangeEnd, rangeStartSafe)
        let usableEnd = containerDuration > 0 ? min(containerDuration, trackEndRaw) : trackEndRaw
        self.trackStart = rangeStartSafe
        self.trackEnd = max(usableEnd, rangeStartSafe)
        self.assetDuration = max(self.trackEnd - self.trackStart, 0)

        let naturalRect = CGRect(origin: .zero, size: track.naturalSize)
        let transformedRect = naturalRect.applying(track.preferredTransform).standardized
        var size = transformedRect.size
        if size.width <= 0 || size.height <= 0 {
            size = track.naturalSize
        }
        self.videoSize = size
    }

    /// Длительность видео в секундах (реальный диапазон кадров видеодорожки,
    /// а не контейнерная длительность с учётом более длинного аудио).
    public var duration: Double { assetDuration }

    /// Размер видео (с учётом поворота).
    public var size: CGSize { videoSize }

    /// Извлекает кадр в момент времени.
    /// - Parameter time: локальное время слайда в секундах (0...duration).
    /// - Returns: кадр (CIImage).
    public func frame(atTime time: Double) throws -> CIImage {
        guard assetDuration > 0 else { throw VideoFrameSourceError.invalidFrameTime }
        let epsilon = 1.0 / 600.0
        let upperBound = max(assetDuration - epsilon, 0)
        let local = min(max(time, 0), upperBound)
        let absolute = trackStart + local

        // 1. Точный кадр (нулевой допуск) — идеальный вариант для плавности.
        if let image = copyImage(generator, atSeconds: absolute) { return cache(image) }
        // 2. Кадр «в точке или сразу после» — когда кадра ровно в точке нет
        //    (смещённый первый кадр, edit list).
        if let image = copyImage(tolerantGenerator, atSeconds: absolute) { return cache(image) }
        // 3. Любой ближайший кадр (ключевой).
        if let image = copyImage(anyGenerator, atSeconds: absolute) { return cache(image) }

        // 4. Скан в обе стороны от запрошенной точки (ограниченное число шагов).
        var offset = 0.1
        var attempts = 0
        while attempts < 200 {
            attempts += 1
            let back = absolute - offset
            if back >= trackStart, let image = copyImage(anyGenerator, atSeconds: back) { return cache(image) }
            let forward = absolute + offset
            if forward <= trackEnd, let image = copyImage(anyGenerator, atSeconds: forward) { return cache(image) }
            offset += 0.1
            if offset > assetDuration + 0.1 { break }
        }

        // 5. Последний удачный кадр — лучше показать его, чем прервать рендер.
        lock.lock()
        let cached = lastGoodFrame
        lock.unlock()
        if let cached { return cached }

        throw VideoFrameSourceError.cannotOpenAsset(
            "frame at \(local)s of \(fileName) (asset \(fmt(assetDuration))s, track \(fmt(trackStart))...\(fmt(trackEnd))s)"
        )
    }

    /// Кэширует первый кадр (для миниатюры в сетке редактора).
    public func thumbnail() throws -> CGImage {
        let t = CMTime(seconds: trackStart, preferredTimescale: 600)
        if let cg = try? generator.copyCGImage(at: t, actualTime: nil) { return cg }
        if let cg = try? tolerantGenerator.copyCGImage(at: t, actualTime: nil) { return cg }
        return try anyGenerator.copyCGImage(at: t, actualTime: nil)
    }

    private func copyImage(_ generator: AVAssetImageGenerator, atSeconds seconds: Double) -> CIImage? {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: t, actualTime: nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    private func cache(_ image: CIImage) -> CIImage {
        lock.lock()
        lastGoodFrame = image
        lock.unlock()
        return image
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Фабрика контекстов рендера: резолвит bookmarks и подготавливает
/// источники кадров для всех слайдов проекта.
public enum SlideContextFactory {

    /// Источник кадров для слайда.
    public enum FrameSource: Sendable {
        case photo(CIImage)
        case video(VideoFrameSource)
    }

    /// Резолвит слайд в источник кадров (с кэшированием по id слайда).
    public static func makeFrameSource(
        reference: MediaReference,
        cachedFrames: inout [UUID: FrameSource]
    ) throws -> FrameSource {
        if let cached = cachedFrames[reference.id] {
            return cached
        }

        let resolved = try MediaResolver.resolveWithAccess(reference)
        let url = resolved.url

        switch reference.kind {
        case .photo:
            // Доступ нужен только на время чтения изображения — после
            // загрузки CIImage держатель можно отпустить.
            // ВАЖНО: загружаем фото с применённой EXIF-ориентацией (upright),
            // чтобы координаты лиц (детекция в том же пространстве) совпадали
            // с пикселями при рендере.
            guard let image = Self.loadUprightPhoto(at: url) else {
                throw BookmarkError.fileUnavailable(reference.displayName)
            }
            let source = FrameSource.photo(image)
            cachedFrames[reference.id] = source
            return source
        case .video:
            // Держатель удерживается внутри VideoFrameSource: кадры
            // читаются лениво (AVAssetImageGenerator), файл может
            // понадобиться в любой момент жизни источника.
            let videoSource = try VideoFrameSource(
                url: url,
                accessHolder: resolved.accessHolder
            )
            let source = FrameSource.video(videoSource)
            cachedFrames[reference.id] = source
            return source
        }
    }

    /// Кэш доступности: возвращает false, если файл недоступен.
    public static func isFileAvailable(_ reference: MediaReference) -> Bool {
        MediaResolver.isAvailable(reference)
    }

    /// Загружает фото в upright-пространстве: EXIF-ориентация применена,
    /// extent соответствует «как показывает пользователь». Полный размер.
    static func loadUprightPhoto(at url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return CIImage(contentsOf: url)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return CIImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return CIImage(contentsOf: url)
        }
        return CIImage(cgImage: cgImage)
    }
}