import Foundation
import AVFoundation
import Photos
import UniformTypeIdentifiers
import SlideStoryModel

/// Ошибки резолвинга медиа-контента.
public enum MediaResolverError: Error, LocalizedError, Sendable {
    case photosAccessDenied
    case photosAssetNotFound(String)
    case photosExportFailed(String)
    case cannotResolve(String)

    public var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            return "Access to the Photos library was denied."
        case .photosAssetNotFound(let id):
            return "Photo library asset not found: \(id)"
        case .photosExportFailed(let reason):
            return "Failed to export photo library asset: \(reason)"
        case .cannotResolve(let name):
            return "Cannot resolve media file: \(name)"
        }
    }
}

/// Результат резолвинга: URL + держатель security-scoped доступа
/// (для ассетов Фото держателя нет — временный файл принадлежит приложению).
public struct ResolvedMedia {
    public let url: URL
    public let accessHolder: SecurityScopedAccess?
}

/// Центральный резолвер контента слайда.
///
/// - Обычный файл: `BookmarkResolver` (security-scoped bookmark).
/// - Ассет медиатеки Фото (`MediaReference.photosLocalIdentifier`):
///   оригинальный файл ассета экспортируется во временную директорию
///   (`NSTemporaryDirectory()/Lumislide-Photos/`) и кэшируется по
///   идентификатору — без постоянных копий в проекте.
public enum MediaResolver {

    private static let cacheDirectoryName = "Lumislide-Photos"

    /// Возвращает URL файла для слайда (без держателя доступа).
    /// - Parameter reference: слайд (bookmark или ассет Фото).
    /// - Throws: `MediaResolverError`, `BookmarkError`.
    public static func resolve(_ reference: MediaReference) throws -> URL {
        try resolveWithAccess(reference).url
    }

    /// Возвращает URL файла слайда и держатель security-scoped доступа
    /// (нужен для источников кадров, читающих файл лениво, в sandbox).
    public static func resolveWithAccess(_ reference: MediaReference) throws -> ResolvedMedia {
        guard reference.isFromPhotosLibrary, let identifier = reference.photosLocalIdentifier else {
            let resolved = try BookmarkResolver.resolve(reference.bookmarkData)
            return ResolvedMedia(url: resolved.url, accessHolder: resolved.accessHolder)
        }
        return ResolvedMedia(url: try exportPhotosAsset(localIdentifier: identifier), accessHolder: nil)
    }

    /// Доступен ли контент слайда (файл существует / ассет экспортируется).
    public static func isAvailable(_ reference: MediaReference) -> Bool {
        guard reference.isFromPhotosLibrary, let identifier = reference.photosLocalIdentifier else {
            return BookmarkResolver.isAvailable(reference.bookmarkData)
        }
        return (try? exportPhotosAsset(localIdentifier: identifier)) != nil
    }

    // MARK: - Фото

    /// Экспортирует оригинальный ресурс ассета во временный файл
    /// (с кэшированием по localIdentifier).
    private static func exportPhotosAsset(localIdentifier: String) throws -> URL {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw MediaResolverError.photosAccessDenied
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            throw MediaResolverError.photosAssetNotFound(localIdentifier)
        }
        guard let resource = primaryResource(for: asset) else {
            throw MediaResolverError.photosExportFailed(localIdentifier)
        }

        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "data"
        let safeID = localIdentifier.replacingOccurrences(of: "/", with: "_")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(safeID).\(ext)")

        // Кэш: переиспользуем ТОЛЬКО валидный файл. После сбоя/прерывания
        // экспорта мог остаться частично записанный файл — раньше он
        // кэшировался навсегда, и рендер падал на извлечении кадров
        // («Cannot open video asset: frame at 0.0s»).
        if FileManager.default.fileExists(atPath: fileURL.path), isValidMediaFile(fileURL) {
            return fileURL
        }
        try? FileManager.default.removeItem(at: fileURL)

        // Пишем во временный файл и переносим атомарно — в кэше не могут
        // появиться частичные файлы.
        let tempURL = directory.appendingPathComponent("\(safeID)-\(UUID().uuidString).part")
        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: nil) { error in
            exportError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let exportError {
            try? FileManager.default.removeItem(at: tempURL)
            throw MediaResolverError.photosExportFailed("\(localIdentifier): \(exportError.localizedDescription)")
        }
        guard isValidMediaFile(tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MediaResolverError.photosExportFailed("\(localIdentifier): invalid/empty media file")
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw MediaResolverError.photosExportFailed("\(localIdentifier): \(error.localizedDescription)")
        }
        return fileURL
    }

    /// Проверяет, что файл — валидный медиафайл (есть дорожка и положительная
    /// длительность). Отсекает частично записанные файлы из кэша.
    private static func isValidMediaFile(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let hasTrack = !asset.tracks(withMediaType: .video).isEmpty
            || !asset.tracks(withMediaType: .audio).isEmpty
        guard hasTrack else { return false }
        let duration = asset.duration.seconds
        return duration.isFinite && duration > 0
    }

    /// Возвращает основной ресурс ассета (оригинал фото или видео).
    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .video:
            // fullSizeVideo — текущая (отредактированная/замедленная) версия;
            // video — оригинал. Предпочитаем первую, как рекомендует Photos.
            return resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
                ?? resources.first
        default: // .image
            return resources.first { $0.type == .photo }
                ?? resources.first { $0.type == .fullSizePhoto }
                ?? resources.first
        }
    }
}
