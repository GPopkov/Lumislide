import Foundation
import CoreMedia
import SlideStoryModel

/// Описание одного слайда на таймлайне.
public struct SlideTimelineItem: Sendable {
    /// Индекс слайда в проекте.
    public var slideIndex: Int
    /// Тип медиа.
    public var kind: MediaKind
    /// Время начала слайда в секундах (на таймлайне итогового видео).
    public var startTime: Double
    /// Время окончания слайда в секундах.
    public var endTime: Double
    /// Длительность в секундах.
    public var duration: Double { endTime - startTime }
    /// Переход, применяемый после этого слайда (nil — последний слайд).
    public var transition: TransitionType?
    /// Длительность перехода после слайда.
    public var transitionDuration: Double
}

/// Раскладка слайдов по времени с перекрытием на переходах.
///
/// Логика:
/// - фото-слайды имеют длительность `photoDuration` из настроек проекта;
/// - видео-слайды имеют фактическую длительность источника (передаётся
///   наружу через `videoDurations`);
/// - каждый слайд (кроме последнего) перекрывается с последующим на
///   время перехода;
/// - переходы не «съедают» слайды: если длительность перехода больше
///   длительности слайда — она клампится к длительности слайда
///   (уточнение ТЗ v1.1, E5).
public enum TimelineBuilder {

    /// Строит таймлайн проекта.
    /// - Parameters:
    ///   - project: проект.
    ///   - videoDurations: длительности видео-слайдов в секундах
    ///     (по индексу слайда; для фото может быть nil/ignored).
    /// - Returns: массив элементов таймлайна в порядке следования.
    public static func buildTimeline(
        project: SlideshowProject,
        videoDurations: [Int: Double] = [:]
    ) -> [SlideTimelineItem] {
        let count = project.slides.count
        guard count > 0 else { return [] }

        var items: [SlideTimelineItem] = []
        var cursor: Double = 0

        for index in 0..<count {
            let slide = project.slides[index]
            let duration: Double
            switch slide.kind {
            case .photo:
                duration = project.defaultPhotoDuration
            case .video:
                duration = videoDurations[index] ?? project.defaultPhotoDuration
            }

            // Переход после этого слайда (если есть следующий).
            let transition = project.transitionType(at: index)
            let transitionDuration: Double
            if transition != nil {
                // Клампим к длительности текущего слайда.
                transitionDuration = min(project.transitionDuration, duration)
            } else {
                transitionDuration = 0
            }

            let end = cursor + duration
            items.append(SlideTimelineItem(
                slideIndex: index,
                kind: slide.kind,
                startTime: cursor,
                endTime: end,
                transition: transition,
                transitionDuration: transitionDuration
            ))

            // Следующий слайд начинается за время перехода до конца текущего.
            cursor = end - transitionDuration
        }

        // Финальная проверка: длительности не могут быть отрицательными.
        return items.map { item in
            var fixed = item
            fixed.endTime = max(fixed.endTime, fixed.startTime + 0.001)
            return fixed
        }
    }

    /// Общая длительность итогового видео в секундах.
    public static func totalDuration(of timeline: [SlideTimelineItem]) -> Double {
        timeline.last?.endTime ?? 0
    }

    /// Возвращает элемент таймлайна в произвольный момент времени.
    /// - Parameter time: время в секундах.
    /// - Returns: элемент и локальное время внутри слайда (0...1).
    public static func slide(at time: Double, in timeline: [SlideTimelineItem]) -> (item: SlideTimelineItem, localTime: Double)? {
        for item in timeline {
            if time >= item.startTime && time < item.endTime {
                let local = (time - item.startTime) / max(item.duration, 0.001)
                return (item, local)
            }
        }
        // Время на границе конца таймлайна.
        if let last = timeline.last, abs(time - last.endTime) < 0.001 {
            return (last, 1.0)
        }
        return nil
    }
}