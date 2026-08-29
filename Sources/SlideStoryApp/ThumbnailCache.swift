import Foundation
import AppKit

/// Дисковый + memory кэш миниатюр медиа-файлов.
///
/// Устраняет ограничение v1 «миниатюры видео — первый кадр без кэша»:
/// миниатюры сохраняются в `~/Library/Caches/Lumislide/Thumbnails/`
/// и переиспользуются между сессиями. Ключ учитывает путь и дату
/// изменения файла, чтобы кэш инвалидировался при замене файла.
///
/// Потокобезопасность: NSCache и FileManager потокобезопасны, кэш
/// используется из фоновых потоков при генерации миниатюр.
final class ThumbnailCache: @unchecked Sendable {

    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let fm = FileManager.default

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        diskDirectory = caches.appendingPathComponent("Lumislide/Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Ключ для файла с учётом времени изменения.
    func key(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let raw = "\(url.path)|\(modified.timeIntervalSince1970)"
        return raw
    }

    /// Возвращает закэшированное изображение, если есть.
    func image(forKey key: String) -> NSImage? {
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        let url = diskDirectory.appendingPathComponent("\(key.hashValue).jpg")
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    /// Сохраняет изображение в кэш (memory + disk как JPEG).
    func store(_ image: NSImage, forKey key: String) {
        memory.setObject(image, forKey: key as NSString)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return
        }
        let url = diskDirectory.appendingPathComponent("\(key.hashValue).jpg")
        try? jpeg.write(to: url)
    }

    /// Очищает дисковый кэш.
    func clearDisk() {
        guard let urls = try? fm.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls {
            try? fm.removeItem(at: url)
        }
        memory.removeAllObjects()
    }
}
