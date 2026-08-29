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
/// в UserDefaults. Используется как `@StateObject` в корне приложения
/// и прокидывается через `environmentObject`.
public final class AppSettings: ObservableObject {

    private enum Keys {
        static let projectsDirectory = "app.projectsDirectory"
        static let defaultPhotoDuration = "app.defaultPhotoDuration"
        static let autosaveEnabled = "app.autosaveEnabled"
        static let language = "app.language"
    }

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

    // MARK: - Локализация

    /// Язык интерфейса.
    @Published public var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
}

import AppKit

extension AppSettings {
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
