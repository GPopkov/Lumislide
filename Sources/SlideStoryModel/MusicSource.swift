import Foundation

/// Источник фоновой музыки.
///
/// В v1 поставляется только пользовательская музыка по ссылке
/// (встроенная библиотека — будущая поставка, см. раздел 15 ТЗ).
public enum MusicSource: Codable, Equatable, Sendable {
    /// Пользовательский аудиофайл, подключённый по security-scoped bookmark.
    case userFile(MediaAudioReference)

    /// Встроенный трек из библиотеки (резервируется на будущее;
    /// в v1 библиотека не поставляется).
    case builtIn(trackID: String)
}

/// Ссылка на пользовательский аудиофайл через security-scoped bookmark.
public struct MediaAudioReference: Codable, Equatable, Sendable {
    public var id: UUID
    /// Security-scoped bookmark (base64-строка).
    public var bookmarkData: String
    /// Отображаемое имя файла.
    public var displayName: String
    /// Длительность в секундах (кэш, заполняется при добавлении).
    public var cachedDuration: Double?

    public init(
        id: UUID = UUID(),
        bookmarkData: String,
        displayName: String,
        cachedDuration: Double? = nil
    ) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.cachedDuration = cachedDuration
    }
}

/// Настройки фоновой музыки проекта.
public struct MusicSettings: Codable, Equatable, Sendable {
    /// Источник музыки; nil — музыка отключена.
    public var source: MusicSource?

    /// Громкость (0.0...1.0), default 0.7.
    public var volume: Double

    /// Секунды плавного затухания/появления вокруг видео-слайдов.
    public static let fadeDuration: Double = 2.0

    public init(source: MusicSource? = nil, volume: Double = 0.7) {
        self.source = source
        self.volume = min(max(volume, 0), 1)
    }
}

/// Координаты «фото-интервалов» для микширования.
///
/// Музыка звучит только на интервалах фото-слайдов (включая переходы
/// между двумя фото). На видео-слайдах звучит собственная дорожка видео:
/// за 2 секунды до начала видео трек плавно затухает, после окончания
/// видео — плавно появляется. Если проект состоит только из видео —
/// музыка не звучит вообще.
public struct PhotoInterval: Codable, Equatable, Sendable {
    /// Начало интервала в секундах (на таймлайне итогового видео).
    public var start: Double
    /// Конец интервала в секундах.
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// Расчёт интервалов «звучания» музыки по таймлайну проекта.
public enum MusicTimelinePlanner {
    /// Длительность фейда вокруг видео-слайдов (из настроек музыки).
    public static let fadeDuration: Double = MusicSettings.fadeDuration

    /// Вычисляет интервалы, на которых должен звучать музыкальный трек.
    ///
    /// Правила (по ТЗ v1.1):
    /// - интервалы соответствуют фото-слайдам, включая переходы между
    ///   двумя фото;
    /// - за `fadeDuration` секунд до начала видео трек гаснет,
    ///   во время видео звучит собственная дорожка видео,
    ///   после видео трек снова появляется;
    /// - если проект состоит только из видео — интервалов нет.
    ///
    /// - Parameters:
    ///   - slideKinds: тип каждого слайда в порядке следования.
    ///   - slideStartTimes: времена начала каждого слайда на таймлайне.
    ///   - slideEndTimes: времена конца каждого слайда (после перехода).
    ///   - transitionDurations: длительности переходов после каждого слайда.
    /// - Returns: массив интервалов (отсортирован по start).
    public static func photoIntervals(
        slideKinds: [MediaKind],
        slideStartTimes: [Double],
        slideEndTimes: [Double],
        transitionDurations: [Double]
    ) -> [PhotoInterval] {
        precondition(slideKinds.count == slideStartTimes.count
                        && slideKinds.count == slideEndTimes.count
                        && slideKinds.count == transitionDurations.count)

        guard slideKinds.contains(.photo) else { return [] }

        var intervals: [PhotoInterval] = []
        let count = slideKinds.count

        var index = 0
        while index < count {
            // Пропускаем видео-слайды.
            if slideKinds[index] != .photo {
                index += 1
                continue
            }

            // Начало фото-интервала: момент start слайда,
            // но не раньше конца фейда после предыдущего видео.
            let start = slideStartTimes[index]

            // Ищем следующий видео-слайд (или конец проекта).
            var endIndex = index
            var end = slideEndTimes[index]
            while endIndex + 1 < count && slideKinds[endIndex + 1] == .photo {
                endIndex += 1
                end = slideEndTimes[endIndex]
            }

            // Если дальше есть видео — заканчиваем интервал
            // за fadeDuration до его начала.
            if endIndex + 1 < count {
                let videoStart = slideStartTimes[endIndex + 1]
                end = min(end, max(start, videoStart - fadeDuration))
            }

            if end > start {
                intervals.append(PhotoInterval(start: start, end: end))
            }

            // Перепрыгиваем следующий видео-слайд, чтобы не создавать
            // нулевые интервалы.
            index = endIndex + 1
            if index < count && slideKinds[index] == .video {
                // Пропускаем видео и все последующие видео.
                while index < count && slideKinds[index] == .video {
                    index += 1
                }
            }
        }

        // Схлопываем соседние интервалы с минимальным разрывом < 0.01 c.
        return normalize(intervals)
    }

    private static func normalize(_ intervals: [PhotoInterval]) -> [PhotoInterval] {
        guard !intervals.isEmpty else { return [] }
        var result: [PhotoInterval] = []
        var current = intervals[0]
        for next in intervals.dropFirst() {
            if next.start - current.end < 0.01 {
                current = PhotoInterval(start: current.start, end: max(current.end, next.end))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }
}