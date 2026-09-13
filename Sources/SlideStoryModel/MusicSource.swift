import Foundation

/// Источник фоновой музыки.
///
/// Поддерживается плейлист из нескольких пользовательских аудиофайлов
/// (проигрываются последовательно по кругу). Встроенная библиотека —
/// будущая поставка.
public enum MusicSource: Equatable, Sendable {
    /// Пользовательские аудиофайлы, подключённые по security-scoped bookmark.
    case userFiles([MediaAudioReference])

    /// Встроенный трек из библиотеки (резервируется на будущее).
    case builtIn(trackID: String)

    /// Ссылки на пользовательские треки (пусто для builtIn).
    public var trackReferences: [MediaAudioReference] {
        if case .userFiles(let tracks) = self { return tracks }
        return []
    }

    /// Есть ли хотя бы один пользовательский трек.
    public var isEmpty: Bool {
        if case .userFiles(let tracks) = self { return tracks.isEmpty }
        return false
    }
}

extension MusicSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, tracks, trackID, audio
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userFiles(let tracks):
            try container.encode("userFiles", forKey: .type)
            try container.encode(tracks, forKey: .tracks)
        case .builtIn(let trackID):
            try container.encode("builtIn", forKey: .type)
            try container.encode(trackID, forKey: .trackID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "builtIn":
            self = .builtIn(trackID: try container.decode(String.self, forKey: .trackID))
        case "userFiles":
            self = .userFiles(try container.decode([MediaAudioReference].self, forKey: .tracks))
        default:
            if let single = try container.decodeIfPresent(MediaAudioReference.self, forKey: .audio) {
                self = .userFiles([single])
            } else if let tracks = try container.decodeIfPresent([MediaAudioReference].self, forKey: .tracks) {
                self = .userFiles(tracks)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown MusicSource")
                )
            }
        }
    }
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

    /// Автоматически приглушать музыку под звуком видео (ducking).
    public var duckingEnabled: Bool

    /// Насколько приглушать музыку под видео (0.0...1.0, 1 = полностью).
    public var duckingLevel: Double

    /// Секунды плавного затухания/появления вокруг видео-слайдов.
    public static let fadeDuration: Double = 1.0

    public init(
        source: MusicSource? = nil,
        volume: Double = 0.7,
        duckingEnabled: Bool = true,
        duckingLevel: Double = 0.5
    ) {
        self.source = source
        self.volume = min(max(volume, 0), 1)
        self.duckingEnabled = duckingEnabled
        self.duckingLevel = min(max(duckingLevel, 0), 1)
    }
}

/// Координаты «фото-интервалов» для микширования.
///
/// Музыка звучит только на интервалах фото-слайдов (включая переходы
/// между двумя фото). На видео-слайдах звучит собственная дорожка видео:
/// за 1 секунду до начала видео трек плавно затухает, после окончания
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
            if slideKinds[index] != .photo {
                index += 1
                continue
            }

            let start = slideStartTimes[index]

            var endIndex = index
            var end = slideEndTimes[index]
            while endIndex + 1 < count && slideKinds[endIndex + 1] == .photo {
                endIndex += 1
                end = slideEndTimes[endIndex]
            }

            if endIndex + 1 < count {
                let videoStart = slideStartTimes[endIndex + 1]
                end = min(end, max(start, videoStart - fadeDuration))
            }

            if end > start {
                intervals.append(PhotoInterval(start: start, end: end))
            }

            index = endIndex + 1
            if index < count && slideKinds[index] == .video {
                while index < count && slideKinds[index] == .video {
                    index += 1
                }
            }
        }

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
