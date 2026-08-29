import Foundation

/// Корневая модель файла проекта `.slideshow` (JSON).
///
/// Каждый проект — отдельный файл на диске. Медиафайлы не импортируются
/// и не копируются — только security-scoped bookmarks.
public struct SlideshowProject: Codable, Identifiable, Equatable, Sendable {
    // MARK: - Константы формата

    /// Версия формата файла проекта.
    public static let currentFileFormatVersion: Int = 1

    /// Расширение файла проекта.
    public static let fileExtension = "slideshow"

    // MARK: - Идентификация

    public var id: UUID

    /// Название проекта (редактируется в свойствах проекта).
    public var name: String

    /// Порядок слайдов = порядок элементов массива. Порядок карточек в
    /// сетке UI соответствует этому массиву; отдельного таймлайна нет.
    public var slides: [MediaReference]

    /// Детерминированный seed переходов и Ken Burns.
    /// 64-битное число хранится строкой, чтобы не терять точность
    /// в JSON-числах (Number теряет точность после 2^53).
    public var transitionSeed: String

    /// 64-битный seed как число.
    public var transitionSeedValue: UInt64 {
        UInt64(transitionSeed) ?? 0
    }

    // MARK: - Слайды

    /// Длительность показа фото по умолчанию (секунды).
    public var defaultPhotoDuration: Double

    /// Длительность переходов (секунды).
    public var transitionDuration: Double

    /// Эффект Кена Бёрнса: глобальный тумблер.
    /// Per-slide отключение — в `MediaReference.isKenBurnsDisabled`.
    public var isKenBurnsEnabled: Bool

    // MARK: - Музыка

    /// Настройки фоновой музыки.
    public var music: MusicSettings

    // MARK: - Экспорт

    /// Настройки экспорта (базовые; в окне экспорта переопределяются
    /// без сохранения обратно).
    public var exportSettings: ExportSettings

    // MARK: - Watch folder (зарезервировано на будущее)

    /// Security-scoped bookmark папки для watch-режима (в v1 не используется).
    public var watchFolderBookmark: String?

    // MARK: - Служебные поля

    /// Версия формата.
    public var fileFormatVersion: Int

    /// Дата последнего сохранения.
    public var updatedAt: Date

    /// Дата создания.
    public var createdAt: Date

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Project",
        slides: [MediaReference] = [],
        transitionSeed: UInt64? = nil,
        defaultPhotoDuration: Double = 5.0,
        transitionDuration: Double = 1.0,
        isKenBurnsEnabled: Bool = true,
        music: MusicSettings = MusicSettings(),
        exportSettings: ExportSettings = ExportSettings(),
        watchFolderBookmark: String? = nil,
        fileFormatVersion: Int = SlideshowProject.currentFileFormatVersion,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.slides = slides
        self.transitionSeed = String(transitionSeed ?? UInt64.random(in: .min ... .max))
        self.defaultPhotoDuration = defaultPhotoDuration
        self.transitionDuration = transitionDuration
        self.isKenBurnsEnabled = isKenBurnsEnabled
        self.music = music
        self.exportSettings = exportSettings
        self.watchFolderBookmark = watchFolderBookmark
        self.fileFormatVersion = fileFormatVersion
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - Codable

    /// Кастомный decoder c миграцией: устаревшие поля восстанавливаются
    /// значениями по умолчанию, отсутствие `transitionSeed` заменяется
    /// на новый случайный seed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Project"
        slides = try container.decodeIfPresent([MediaReference].self, forKey: .slides) ?? []
        transitionSeed = try container.decodeIfPresent(String.self, forKey: .transitionSeed)
            ?? String(UInt64.random(in: .min ... .max))
        defaultPhotoDuration = try container.decodeIfPresent(Double.self, forKey: .defaultPhotoDuration) ?? 5.0
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 1.0
        isKenBurnsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isKenBurnsEnabled) ?? true
        music = try container.decodeIfPresent(MusicSettings.self, forKey: .music) ?? MusicSettings()
        exportSettings = try container.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? ExportSettings()
        watchFolderBookmark = try container.decodeIfPresent(String.self, forKey: .watchFolderBookmark)
        fileFormatVersion = try container.decodeIfPresent(Int.self, forKey: .fileFormatVersion)
            ?? SlideshowProject.currentFileFormatVersion
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    // MARK: - Операции

    /// Добавляет медиа-элемент в конец массива слайдов.
    public mutating func append(_ reference: MediaReference) {
        slides.append(reference)
        touch()
    }

    /// Вставляет медиа-элемент по индексу.
    public mutating func insert(_ reference: MediaReference, at index: Int) {
        slides.insert(reference, at: min(max(index, 0), slides.count))
        touch()
    }

    /// Удаляет слайд по id.
    /// - Returns: true, если слайд был найден и удалён.
    @discardableResult
    public mutating func removeSlide(id: UUID) -> Bool {
        let oldCount = slides.count
        slides.removeAll { $0.id == id }
        let removed = slides.count != oldCount
        if removed { touch() }
        return removed
    }

    /// Перемещает слайд с одного индекса на другой (drag&drop reorder).
    /// - Parameter sourceIndex: исходный индекс (0-based).
    /// - Parameter destinationIndex: целевой индекс (0-based, после удаления источника).
    public mutating func moveSlide(from sourceIndex: Int, to destinationIndex: Int) {
        guard slides.indices.contains(sourceIndex),
              slides.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let element = slides.remove(at: sourceIndex)
        slides.insert(element, at: destinationIndex)
        touch()
    }

    /// Возвращает детерминированный переход для слайда по индексу
    /// с учётом override.
    /// - Parameter slideIndex: индекс слайда.
    /// - Returns: тип перехода (если слайд последний — никуда не переходит).
    public func transitionType(at slideIndex: Int) -> TransitionType? {
        guard slides.indices.contains(slideIndex), slideIndex < slides.count - 1 else { return nil }
        if let override = slides[slideIndex].transitionOverride {
            return override
        }
        return TransitionPicker.transition(seed: transitionSeedValue, slideIndex: slideIndex)
    }

    /// Маркирует изменение проекта.
    private mutating func touch() {
        updatedAt = Date()
    }
}