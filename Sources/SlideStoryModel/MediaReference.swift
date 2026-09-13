import Foundation
import CoreGraphics

/// Тип медиа-элемента слайда.
public enum MediaKind: String, Codable, Sendable {
    case photo
    case video
}

/// Прямоугольник лица, найденный Vision-детектором (нормализованные координаты).
///
/// Координаты нормализованы относительно исходного изображения
/// (0.0...1.0), origin — верхний левый угол (как в Vision).
public struct FaceRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Объединяющий прямоугольник для набора лиц (nullable, если набор пуст).
    public static func union(of regions: [FaceRegion]) -> FaceRegion? {
        guard let first = regions.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for region in regions.dropFirst() {
            minX = min(minX, region.x)
            minY = min(minY, region.y)
            maxX = max(maxX, region.x + region.width)
            maxY = max(maxY, region.y + region.height)
        }
        return FaceRegion(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Ссылка на медиафайл на диске через security-scoped bookmark.
///
/// Файл не импортируется и не копируется — хранится ссылка. Bookmark
/// позволяет получить доступ к файлу и в sandbox, и вне его.
public struct MediaReference: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Тип медиа: фото или видео.
    public var kind: MediaKind

    /// Security-scoped bookmark (base64-строка).
    public var bookmarkData: String

    /// Отображаемое имя файла (для карточки в UI).
    public var displayName: String

    /// Принудительный переход к следующему слайду (override).
    /// nil — автоматический (детерминированный по seed).
    public var transitionOverride: TransitionType?

    /// Титр поверх слайда; nil — титра нет.
    public var titleOverlay: TitleOverlay?

    /// Per-slide отключение эффекта Кена Бёрнса (только для фото).
    public var isKenBurnsDisabled: Bool

    /// Кэш найденных лиц (нормализованные bounding boxes).
    /// Рассчитывается один раз и сохраняется в файле проекта.
    /// Устаревание кэша при замене файла на диске — осознанное ограничение v1.
    public var faceRegions: [FaceRegion]

    /// Версия/эпоха алгоритма детекции лиц. Нужна для инвалидации старых
    /// кэшей: координаты лиц всегда хранятся в «выпрямленном» (upright)
    /// пространстве пикселей с учётом EXIF-ориентации. Значения старых
    /// версий (nil/0/1) считаются устаревшими и пересчитываются.
    public var faceRegionsEpoch: Int?

    /// Кэш длительности видео-слайда (секунды), заполняется рендерером.
    public var cachedVideoDuration: Double?

    /// Per-slide длительность (секунды). nil — значение по умолчанию
    /// (для фото — defaultPhotoDuration, для видео — фактическая длительность).
    public var customDuration: Double?

    /// Для видео: показывать ролик целиком (по умолчанию true).
    /// Если false и задана customDuration — видео обрезается до неё.
    public var playFullVideo: Bool

    /// Идентификатор PHAsset в медиатеке Фото (если слайд взят из Фото).
    /// В этом случае `bookmarkData` не используется: контент экспортируется
    /// во временный файл в момент предпросмотра/экспорта (без копий).
    public var photosLocalIdentifier: String?

    /// Текущая «эпоха» детекции лиц (инвалидирует старые кэши координат).
    /// Единый источник истины для приложения и рендерера.
    public static let currentFaceRegionsEpoch = 2

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        bookmarkData: String,
        displayName: String,
        transitionOverride: TransitionType? = nil,
        titleOverlay: TitleOverlay? = nil,
        isKenBurnsDisabled: Bool = false,
        faceRegions: [FaceRegion] = [],
        faceRegionsEpoch: Int? = nil,
        cachedVideoDuration: Double? = nil,
        photosLocalIdentifier: String? = nil,
        customDuration: Double? = nil,
        playFullVideo: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.transitionOverride = transitionOverride
        self.titleOverlay = titleOverlay
        self.isKenBurnsDisabled = isKenBurnsDisabled
        self.faceRegions = faceRegions
        self.faceRegionsEpoch = faceRegionsEpoch
        self.cachedVideoDuration = cachedVideoDuration
        self.photosLocalIdentifier = photosLocalIdentifier
        self.customDuration = customDuration
        self.playFullVideo = playFullVideo
    }

    /// Является ли слайд ссылкой на ассет медиатеки Фото.
    public var isFromPhotosLibrary: Bool {
        guard let photosLocalIdentifier else { return false }
        return !photosLocalIdentifier.isEmpty
    }
}

/// Live Photo пара: неподвижный кадр (HEIC) + короткое видео (MOV).
///
/// В v1 при добавлении HEIC приложение ищет рядом MOV с тем же базовым
/// именем. Если пара найдена — слайд ведёт себя как видео (движение),
/// иначе — как статичное фото.
public struct LivePhotoPair: Sendable {
    public let stillBookmarkData: String
    public let videoBookmarkData: String
    public let displayName: String
}
extension MediaReference {
    private enum CodingKeys: String, CodingKey {
        case id, kind, bookmarkData, displayName, transitionOverride, titleOverlay,
             isKenBurnsDisabled, faceRegions, faceRegionsEpoch, cachedVideoDuration,
             photosLocalIdentifier, customDuration, playFullVideo
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(bookmarkData, forKey: .bookmarkData)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(transitionOverride, forKey: .transitionOverride)
        try c.encodeIfPresent(titleOverlay, forKey: .titleOverlay)
        try c.encode(isKenBurnsDisabled, forKey: .isKenBurnsDisabled)
        try c.encode(faceRegions, forKey: .faceRegions)
        try c.encodeIfPresent(faceRegionsEpoch, forKey: .faceRegionsEpoch)
        try c.encodeIfPresent(cachedVideoDuration, forKey: .cachedVideoDuration)
        try c.encodeIfPresent(photosLocalIdentifier, forKey: .photosLocalIdentifier)
        try c.encodeIfPresent(customDuration, forKey: .customDuration)
        try c.encode(playFullVideo, forKey: .playFullVideo)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        bookmarkData = try c.decode(String.self, forKey: .bookmarkData)
        displayName = try c.decode(String.self, forKey: .displayName)
        transitionOverride = try c.decodeIfPresent(TransitionType.self, forKey: .transitionOverride)
        titleOverlay = try c.decodeIfPresent(TitleOverlay.self, forKey: .titleOverlay)
        isKenBurnsDisabled = try c.decodeIfPresent(Bool.self, forKey: .isKenBurnsDisabled) ?? false
        faceRegions = try c.decodeIfPresent([FaceRegion].self, forKey: .faceRegions) ?? []
        faceRegionsEpoch = try c.decodeIfPresent(Int.self, forKey: .faceRegionsEpoch)
        cachedVideoDuration = try c.decodeIfPresent(Double.self, forKey: .cachedVideoDuration)
        photosLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .photosLocalIdentifier)
        customDuration = try c.decodeIfPresent(Double.self, forKey: .customDuration)
        playFullVideo = try c.decodeIfPresent(Bool.self, forKey: .playFullVideo) ?? true
    }
}
