import Foundation

/// Ошибки резолвинга security-scoped bookmarks.
public enum BookmarkError: Error, LocalizedError, Equatable, Sendable {
    /// В bookmark-данных повреждена или неверная кодировка.
    case invalidBookmarkData
    /// Файл по bookmark не найден или недоступен (перемещён/удалён/нет доступа).
    case fileUnavailable(String)
    /// Security-scoped доступ отклонён системой.
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .invalidBookmarkData:
            return "Invalid bookmark data."
        case .fileUnavailable(let name):
            return "File not available: \(name)."
        case .accessDenied:
            return "Access to the file was denied."
        }
    }
}

/// Результат резолвинга: url + держатель security-scoped доступа.
public struct ResolvedMediaFile: Sendable {
    /// URL файла.
    public let url: URL
    /// Активный security-scoped доступ.
    /// Пока держатель жив, доступ к файлу разрешён.
    public let accessHolder: SecurityScopedAccess

    /// Короче: url файла.
    public var fileURL: URL { url }

    /// Является ли файл доступным (существует и открывается).
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Держатель security-scoped доступа: продлевает жизнь доступa
/// на время работы с файлом.
public final class SecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private var isStarted: Bool

    public init(url: URL, isStarted: Bool) {
        self.url = url
        self.isStarted = isStarted
    }

    deinit {
        stop()
    }

    /// Завершает security-scoped доступ (вызывается автоматически в deinit).
    public func stop() {
        guard isStarted else { return }
        url.stopAccessingSecurityScopedResource()
        isStarted = false
    }
}

/// Резолвинг security-scoped bookmarks.
///
/// Используется и в sandbox, и вне его. `MediaReference.bookmarkData`
/// хранит base64-кодированный bookmark, созданный при выборе файла
/// через `NSOpenPanel` (в sandbox — с опцией `.withSecurityScope`).
public enum BookmarkResolver {
    /// Опции создания bookmarks (используются при добавлении файлов).
    public static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]

    /// Создаёт security-scoped bookmark для файла.
    /// - Parameter url: URL файла.
    /// - Returns: base64-строка bookmark.
    /// - Throws: если создать bookmark не удалось.
    public static func createBookmark(for url: URL) throws -> String {
        let data = try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return data.base64EncodedString()
    }

    /// Резолвит bookmark в URL файла.
    /// - Parameter base64: base64-строка bookmark.
    /// - Returns: URL файла (без старта security-scoped доступа).
    /// - Throws: `BookmarkError.invalidBookmarkData`.
    public static func url(fromBookmark base64: String) throws -> URL {
        guard let data = Data(base64Encoded: base64) else {
            throw BookmarkError.invalidBookmarkData
        }
        var isStale = false
        let url = try urlFromBookmarkData(data, isStale: &isStale)
        return url
    }

    /// Резолвит bookmark и открывает security-scoped доступ.
    /// - Parameter base64: base64-строка bookmark.
    /// - Returns: `ResolvedMediaFile` с активным доступом.
    /// - Throws: `BookmarkError` если bookmark невалиден или доступ запрещён.
    public static func resolve(_ base64: String) throws -> ResolvedMediaFile {
        guard let data = Data(base64Encoded: base64) else {
            throw BookmarkError.invalidBookmarkData
        }

        var isStale = false
        let url = try urlFromBookmarkData(data, isStale: &isStale)

        let accessGranted = url.startAccessingSecurityScopedResource()
        guard accessGranted else {
            throw BookmarkError.accessDenied
        }

        return ResolvedMediaFile(
            url: url,
            accessHolder: SecurityScopedAccess(url: url, isStarted: true)
        )
    }

    /// Проверяет доступность bookmark без старта доступа.
    /// - Parameter base64: base64-строка bookmark.
    public static func isAvailable(_ base64: String) -> Bool {
        guard let url = try? url(fromBookmark: base64) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Обновляет «устаревший» bookmark (URL сместился после обновления ОС/app).
    public static func refreshedBookmark(base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else {
            throw BookmarkError.invalidBookmarkData
        }
        var isStale = false
        let url = try urlFromBookmarkData(data, isStale: &isStale)
        guard isStale else { return base64 }
        let refreshed = try createBookmark(for: url)
        return refreshed
    }

    // MARK: - Internals

    private static func urlFromBookmarkData(_ data: Data, isStale: inout Bool) throws -> URL {
        do {
            return try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw BookmarkError.invalidBookmarkData
        }
    }
}