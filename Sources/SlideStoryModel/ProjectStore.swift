import Foundation

/// Ошибки работы с файлами проектов.
public enum ProjectStoreError: Error, LocalizedError, Sendable {
    case cannotCreateDirectory(String)
    case cannotSave(String)
    case cannotLoad(String)
    case invalidProjectFile

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            return "Cannot create directory: \(path)."
        case .cannotSave(let path):
            return "Cannot save project: \(path)."
        case .cannotLoad(let path):
            return "Cannot load project: \(path)."
        case .invalidProjectFile:
            return "The file is not a valid Lumislide project."
        }
    }
}

/// Хранилище файлов проектов на диске.
///
/// Каждый проект — отдельный файл `.slideshow` (JSON). Управляет
/// атомарным сохранением (в temp + rename) и загрузкой с миграцией
/// формата через кастомный decoder `SlideshowProject`.
public struct ProjectStore: Sendable {
    /// URL файла проекта.
    public let fileURL: URL

    /// Расширение файла проекта.
    public static let fileExtension = SlideshowProject.fileExtension

    // MARK: - Init

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Load

    /// Загружает проект из файла.
    /// - Returns: проект.
    /// - Throws: `ProjectStoreError`.
    public func load() throws -> SlideshowProject {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProjectStoreError.cannotLoad(fileURL.path)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .useDefaultKeys

        do {
            return try decoder.decode(SlideshowProject.self, from: data)
        } catch {
            // Попытка прочитать как legacy JSON (если машина изменила
            // стратегию дат) — не обязательна, но дешевле, чем терять проект.
            let legacyDecoder = JSONDecoder()
            legacyDecoder.dateDecodingStrategy = .secondsSince1970
            do {
                return try legacyDecoder.decode(SlideshowProject.self, from: data)
            } catch {
                throw ProjectStoreError.invalidProjectFile
            }
        }
    }

    /// Загружает проект, попутно обновляя «устаревшие» bookmarks.
    /// - Returns: (проект, нужно ли сохранить обновлённые bookmarks).
    public func loadWithBookmarkRefresh() throws -> (project: SlideshowProject, needsSave: Bool) {
        var project = try load()
        var needsSave = false
        for index in project.slides.indices {
            if let refreshed = try? BookmarkResolver.refreshedBookmark(
                base64: project.slides[index].bookmarkData
            ), refreshed != project.slides[index].bookmarkData {
                project.slides[index].bookmarkData = refreshed
                needsSave = true
            }
        }
        if case .userFile(let audio) = project.music.source {
            if let refreshed = try? BookmarkResolver.refreshedBookmark(base64: audio.bookmarkData),
               refreshed != audio.bookmarkData {
                project.music.source = .userFile(MediaAudioReference(
                    id: audio.id,
                    bookmarkData: refreshed,
                    displayName: audio.displayName,
                    cachedDuration: audio.cachedDuration
                ))
                needsSave = true
            }
        }
        return (project, needsSave)
    }

    // MARK: - Save

    /// Сохраняет проект в файл (атомарно: temp + rename).
    /// - Parameter project: проект.
    /// - Throws: `ProjectStoreError`.
    public func save(_ project: SlideshowProject) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(project)
        } catch {
            throw ProjectStoreError.cannotSave(fileURL.path)
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProjectStoreError.cannotCreateDirectory(directory.path)
        }

        let tempURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )

        do {
            try data.write(to: tempURL, options: .atomic)
            // Замена файла через replaceItemAt — атомарно даже в sandbox.
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProjectStoreError.cannotSave(fileURL.path)
        }
    }

    // MARK: - Helpers

    /// Проверяет наличие файла проекта на диске.
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Человекочитаемое имя файла (без расширения) — для списка проектов.
    public var fileName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}

/// Директория с проектами по умолчанию (из настроек приложения).
public enum DefaultProjectsDirectory {
    /// Стандартная папка пользователя: `~/Lumislide Projects`.
    public static var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Lumislide Projects", isDirectory: true)
    }

    /// Создаёт папку по умолчанию, если её нет.
    public static func ensureExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}