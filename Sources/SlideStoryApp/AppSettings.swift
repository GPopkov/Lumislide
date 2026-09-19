import Foundation
import Combine
import SlideStoryModel

/// Язык интерфейса приложения (переключается в настройках).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
}

/// Общие настройки приложения (UserDefaults-backed).
///
/// Свойства публикуются через `@Published`, изменения сохраняются
/// в UserDefaults. Общий экземпляр — `AppSettings.shared`; прокидывается
/// в сцены через `environmentObject`.
public final class AppSettings: ObservableObject {

    private enum Keys {
        static let projectsDirectory = "app.projectsDirectory"
        static let defaultPhotoDuration = "app.defaultPhotoDuration"
        static let autosaveEnabled = "app.autosaveEnabled"
        static let language = "app.language"
        static let thumbnailSize = "app.thumbnailSize"
        static let lastProjectPath = "app.lastProjectPath"
        static let exportRatioH264 = "app.exportRatio.h264"
        static let exportRatioH265 = "app.exportRatio.h265"
    }

    /// Допустимый диапазон размера (ширины) карточек миниатюр.
    public static let thumbnailSizeRange: ClosedRange<Double> = 120...600

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.projectsDirectory),
           let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL? {
            _projectsDirectory = Published(initialValue: url)
        } else {
            _projectsDirectory = Published(initialValue: DefaultProjectsDirectory.url)
        }

        _defaultPhotoDuration = Published(initialValue: defaults.object(forKey: Keys.defaultPhotoDuration) as? Double ?? 5.0)
        _autosaveEnabled = Published(initialValue: defaults.object(forKey: Keys.autosaveEnabled) as? Bool ?? true)
        _language = Published(initialValue: AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "en") ?? .english)
        let storedThumbnail = defaults.object(forKey: Keys.thumbnailSize) as? Double ?? 180.0
        _thumbnailSize = Published(initialValue: Self.clampThumbnailSize(storedThumbnail))
        _lastProjectPath = Published(initialValue: defaults.string(forKey: Keys.lastProjectPath))
    }

    // MARK: - Папка проектов

    /// Папка, где по умолчанию хранятся файлы проектов (.slideshow).
    @Published public var projectsDirectory: URL {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: projectsDirectory, requiringSecureCoding: true) {
                defaults.set(data, forKey: Keys.projectsDirectory)
            }
        }
    }

    // MARK: - Параметры по умолчанию

    /// Длительность показа фото по умолчанию (секунды).
    @Published public var defaultPhotoDuration: Double {
        didSet { defaults.set(defaultPhotoDuration, forKey: Keys.defaultPhotoDuration) }
    }

    /// Автосохранение проекта (по изменению и при выходе).
    @Published public var autosaveEnabled: Bool {
        didSet { defaults.set(autosaveEnabled, forKey: Keys.autosaveEnabled) }
    }

    // MARK: - Оценка размера экспорта

    /// Поправочный коэффициент к оценке размера (факт / оценка по целевому
    /// битрейту). Учится на реальных экспортах: слайдшоу из статичных фото
    /// сжимается лучше целевого битрейта, поэтому оценка «по битрейту»
    /// завышена. 1.0 — оценка ещё не калибровалась.
    public func exportBitrateRatio(for codec: VideoCodec) -> Double {
        let key = codec == .h265 ? Keys.exportRatioH265 : Keys.exportRatioH264
        guard let stored = defaults.object(forKey: key) as? Double, stored > 0.05 else { return 1.0 }
        return min(max(stored, 0.05), 1.5)
    }

    /// Запоминает фактическое соотношение размера к оценке (экспоненциальное
    /// сглаживание, чтобы оценка сходилась к реальности на этом контенте).
    public func recordExportSize(actualBytes: Int, estimatedBytes: Double, codec: VideoCodec) {
        guard actualBytes > 0, estimatedBytes > 0 else { return }
        let ratio = min(max(Double(actualBytes) / estimatedBytes, 0.05), 1.5)
        let key = codec == .h265 ? Keys.exportRatioH265 : Keys.exportRatioH264
        let previous = defaults.object(forKey: key) as? Double
        let smoothed = previous.map { $0 * 0.5 + ratio * 0.5 } ?? ratio
        defaults.set(smoothed, forKey: key)
    }

    // MARK: - Локализация

    /// Язык интерфейса.
    @Published public var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    // MARK: - Сетка миниатюр

    /// Размер (ширина) карточек миниатюр в сетке редактора.
    @Published public var thumbnailSize: Double {
        didSet { defaults.set(thumbnailSize, forKey: Keys.thumbnailSize) }
    }

    // MARK: - Последний проект

    /// Путь последнего открытого проекта — открывается автоматически при запуске.
    @Published public var lastProjectPath: String? {
        didSet { defaults.set(lastProjectPath, forKey: Keys.lastProjectPath) }
    }

    /// Приводит размер карточек к допустимому диапазону.
    public static func clampThumbnailSize(_ value: Double) -> Double {
        min(max(value, thumbnailSizeRange.lowerBound), thumbnailSizeRange.upperBound)
    }
}

import AppKit

extension AppSettings {
    /// Общий экземпляр настроек приложения (UserDefaults.standard).
    public static let shared = AppSettings()

    /// Диалог выбора папки проектов.
    public func chooseProjectsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Lumislide projects"
        if panel.runModal() == .OK, let url = panel.url {
            projectsDirectory = url
        }
    }
}
