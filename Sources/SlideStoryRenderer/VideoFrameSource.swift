import Foundation
import AVFoundation
import CoreImage
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
    private let generator: AVAssetImageGenerator
    private let assetDuration: Double
    private let videoSize: CGSize
    /// Удерживает security-scoped доступ к файлу на всё время жизни
    /// источника (иначе доступ закроется сразу после резолвинга).
    private let accessHolder: SecurityScopedAccess?

    /// Инициализирует источник кадров для файла.
    /// - Parameters:
    ///   - url: URL видеофайла.
    ///   - accessHolder: держатель security-scoped доступа (удерживается).
    /// - Throws: `VideoFrameSourceError`.
    public init(url: URL, accessHolder: SecurityScopedAccess? = nil) throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        self.accessHolder = accessHolder

        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoFrameSourceError.noVideoTrack
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator

        // ВАЖНО: контейнерная длительность может быть больше реального
        // диапазона видеодорожки — у многих файлов (запись экрана, mux с более
        // длинным аудио) `asset.duration` задаётся самой длинной дорожкой,
        // а кадров в «хвосте» нет. Для извлечения кадров берём минимум из
        // длительности контейнера и времени окончания видеодорожки, иначе
        // запрос кадра в «хвосте» падает с ошибкой (см. «frame at 29,9s»).
        let containerDuration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        let trackDuration = track.timeRange.duration.seconds
        let usableDuration: Double
        if trackDuration.isFinite, trackDuration > 0 {
            usableDuration = min(containerDuration, trackDuration)
        } else {
            usableDuration = containerDuration
        }
        self.assetDuration = max(usableDuration, 0)

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
    /// - Parameter time: время в секундах (0...duration).
    /// - Returns: кадр (CIImage).
    public func frame(atTime time: Double) throws -> CIImage {
        guard assetDuration > 0 else { throw VideoFrameSourceError.invalidFrameTime }
        // Последний кадр может быть раньше заявленной длительности контейнера;
        // отступаем от реального конца дорожки на малую величину.
        let epsilon = 1.0 / 600.0
        let upperBound = max(assetDuration - epsilon, 0)
        let clamped = min(max(time, 0), upperBound)
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
            return CIImage(cgImage: cgImage)
        } catch {
            // Запасной вариант: если точный кадр в этой точке недоступен
            // (декодер не находит кадр у самого конца файла), отступаем
            // назад небольшими шагами, пока кадр не найдётся.
            var fallback = clamped
            for _ in 0..<10 {
                fallback = max(fallback - 0.1, 0)
                let fallbackTime = CMTime(seconds: fallback, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: fallbackTime, actualTime: nil) {
                    return CIImage(cgImage: cgImage)
                }
            }
            throw VideoFrameSourceError.cannotOpenAsset("frame at \(clamped)s")
        }
    }

    /// Кэширует первый кадр (для миниатюры в сетке редактора).
    public func thumbnail() throws -> CGImage {
        try generator.copyCGImage(at: .zero, actualTime: nil)
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

        let resolved = try BookmarkResolver.resolve(reference.bookmarkData)
        let url = resolved.url

        switch reference.kind {
        case .photo:
            // Доступ нужен только на время чтения изображения — после
            // загрузки CIImage держатель можно отпустить.
            guard let image = CIImage(contentsOf: url) else {
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
        BookmarkResolver.isAvailable(reference.bookmarkData)
    }
}