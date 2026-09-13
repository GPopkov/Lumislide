import Foundation
import SlideStoryModel

/// Резолвер фактической длительности видео-слайдов.
///
/// Единый источник истины для предпросмотра и экспорта. Использует кэш
/// `MediaReference.cachedVideoDuration`, а при его отсутствии — живое
/// открытие `VideoFrameSource`. Это исключает ситуацию, когда видео-слайд
/// без найденной длительности «становится фото» и обрезается до
/// `defaultPhotoDuration`.
public enum MediaDurationResolver {

    /// Длительность видео-слайда в секундах (nil — не удалось определить).
    public static func videoDuration(for slide: MediaReference) -> Double? {
        guard slide.kind == .video else { return nil }
        if let cached = slide.cachedVideoDuration, cached > 0 {
            return cached
        }
        guard let resolved = try? MediaResolver.resolveWithAccess(slide),
              let source = try? VideoFrameSource(url: resolved.url, accessHolder: resolved.accessHolder),
              source.duration > 0 else {
            return slide.cachedVideoDuration
        }
        return source.duration
    }

    /// Карта «индекс слайда → длительность» для всех видео-слайдов проекта.
    public static func resolveVideoDurations(project: SlideshowProject) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (index, slide) in project.slides.enumerated() where slide.kind == .video {
            if let duration = videoDuration(for: slide) {
                result[index] = duration
            }
        }
        return result
    }
}
