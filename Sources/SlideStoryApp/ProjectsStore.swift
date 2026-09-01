import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import Photos
#if canImport(_PhotosUI_SwiftUI)
import _PhotosUI_SwiftUI
#else
import PhotosUI
#endif
import SlideStoryModel
import SlideStoryRenderer

/// Ошибки работы с проектами на уровне UI.
public enum ProjectsStoreError: Error, LocalizedError {
    case noCurrentProject

    public var errorDescription: String? {
        switch self {
        case .noCurrentProject: return "No project is open."
        }
    }
}

/// ViewModel списка проектов и текущего проекта.
///
/// - `projects` — URL-ы всех `.slideshow` файлов в папке проектов;
/// - `currentProject` — открытый проект (или nil);
/// - операции: создать / открыть / сохранить / добавить медиа /
///   удалить слайд / переместить слайд (drag&drop reorder).
@MainActor
public final class ProjectsStore: ObservableObject {

    @Published public var projects: [URL] = []
    @Published public var currentProject: SlideshowProject?
    @Published public var currentProjectURL: URL?
    /// Сохранён ли текущий проект (для маркера «изменено»).
    @Published public var isDirty = false

    private let settings: AppSettings
    private var lastSavedName = ""

    public init(settings: AppSettings) {
        self.settings = settings
        reloadProjects()
    }

    // MARK: - Список проектов

    /// Перечитывает список `.slideshow` файлов в папке проектов.
    public func reloadProjects() {
        let fm = FileManager.default
        let dir = settings.projectsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }

        projects = urls
            .filter { $0.pathExtension.lowercased() == SlideshowProject.fileExtension }
            .sorted {
                let d0 = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let d1 = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (d0 ?? .distantPast) > (d1 ?? .distantPast)
            }
    }

    /// Создаёт новый проект в папке проектов и открывает его.
    /// Имя файла уникализируется (Untitled, Untitled 2, ...), чтобы
    /// не перезаписывать существующий проект.
    public func createNewProject() {
        var project = SlideshowProject(name: "Untitled")
        project.defaultPhotoDuration = settings.defaultPhotoDuration

        let fm = FileManager.default
        var fileURL = settings.projectsDirectory.appendingPathComponent("Untitled.slideshow")
        var counter = 2
        while fm.fileExists(atPath: fileURL.path) {
            fileURL = settings.projectsDirectory
                .appendingPathComponent("Untitled \(counter).slideshow")
            counter += 1
        }

        let store = ProjectStore(fileURL: fileURL)
        try? store.save(project)

        currentProject = project
        currentProjectURL = store.fileURL
        isDirty = false
        reloadProjects()
    }

    /// Открывает проект по URL.
    public func openProject(at url: URL) {
        let store = ProjectStore(fileURL: url)
        guard let (project, _) = try? store.loadWithBookmarkRefresh() else { return }
        currentProject = project
        currentProjectURL = url
        isDirty = false
        lastSavedName = project.name
        reloadProjects()
    }

    /// Удаляет проект с диска (и из списка, если открыт).
    public func deleteProject(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if currentProjectURL == url {
            currentProject = nil
            currentProjectURL = nil
            isDirty = false
        }
        reloadProjects()
    }

    // MARK: - Сохранение

    /// Сохраняет текущий проект в файл.
    /// Если имя проекта изменилось — файл на диске переименовывается,
    /// чтобы список проектов в главном окне соответствовал названию.
    public func saveCurrentProject() throws {
        guard let project = currentProject else { throw ProjectsStoreError.noCurrentProject }

        let fm = FileManager.default
        var targetURL = currentProjectURL ?? defaultURL(for: project.name)

        // Переименование файла при смене имени проекта.
        if let existingURL = currentProjectURL,
           existingURL.deletingPathExtension().lastPathComponent != project.name {
            let newURL = defaultURL(for: project.name)
            // Не перезаписываем другой существующий файл: если имя занято,
            // остаёмся на старом файле.
            if !fm.fileExists(atPath: newURL.path) {
                do {
                    try fm.moveItem(at: existingURL, to: newURL)
                    targetURL = newURL
                } catch {
                    // Не удалось переименовать — сохраняем в старый файл.
                    targetURL = existingURL
                }
            }
        }

        let store = ProjectStore(fileURL: targetURL)
        try store.save(project)
        currentProjectURL = targetURL
        isDirty = false
        lastSavedName = project.name
        reloadProjects()
    }

    private func defaultURL(for name: String) -> URL {
        settings.projectsDirectory.appendingPathComponent("\(name).slideshow")
    }

    // MARK: - Изменение текущего проекта

    /// Атомарно мутирует текущий проект и помечает его как изменённый.
    public func mutate(_ block: (inout SlideshowProject) -> Void) {
        guard var project = currentProject else { return }
        block(&project)
        project.updatedAt = Date()
        currentProject = project
        isDirty = true
        if settings.autosaveEnabled {
            try? saveCurrentProject()
        }
    }

    // MARK: - Медиа

    /// Открывает NSOpenPanel с множественным выбором и добавляет файлы
    /// в конец текущего проекта (без копирования — только bookmarks).
    public func addMedia() {
        guard currentProject != nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MediaImporter.allowedContentTypes
        panel.message = L10n.text(.addMedia)

        guard panel.runModal() == .OK else { return }

        var newSlides: [MediaReference] = []
        for url in panel.urls {
            guard let kind = MediaImporter.mediaKind(for: url) else { continue }
            guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { continue }

            // Live Photo: если выбран HEIC и рядом есть MOV с тем же именем —
            // слайд ведёт себя как видео (движение).
            var refKind = kind
            var bookmarkData = bookmark
            if kind == .photo,
               let videoURL = MediaImporter.livePhotoVideoURL(for: url),
               let videoBookmark = try? BookmarkResolver.createBookmark(for: videoURL) {
                refKind = .video
                bookmarkData = videoBookmark
            }

            newSlides.append(MediaReference(
                kind: refKind,
                bookmarkData: bookmarkData,
                displayName: url.lastPathComponent
            ))
        }

        guard !newSlides.isEmpty else { return }
        mutate { project in
            project.slides.append(contentsOf: newSlides)
        }

        // Детекция лиц для фото — заранее (кэшируется в MediaReference),
        // чтобы Ken Burns учитывал лица при предпросмотре/экспорте.
        for slide in newSlides where slide.kind == .photo {
            precomputeFaces(for: slide.id)
        }
    }

    /// Добавляет выбранные элементы медиатеки Фото в конец проекта.
    /// Хранятся ссылки на PHAsset (`photosLocalIdentifier`), контент
    /// экспортируется во временный файл при предпросмотре/экспорте.
    /// - Parameter items: выбранные элементы `PhotosPicker`.
    public func addPhotos(_ items: [PhotosPickerItem]) {
        guard currentProject != nil, !items.isEmpty else { return }
        let identifiers = items.compactMap { $0.itemIdentifier }
        guard !identifiers.isEmpty else { return }

        // Определяем тип и имя по ассету.
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var references: [MediaReference] = []
        assets.enumerateObjects { asset, _, _ in
            let kind: MediaKind = asset.mediaType == .video ? .video : .photo
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
                ?? asset.localIdentifier
            references.append(MediaReference(
                kind: kind,
                bookmarkData: "",
                displayName: name,
                photosLocalIdentifier: asset.localIdentifier
            ))
        }
        guard !references.isEmpty else { return }

        mutate { project in
            project.slides.append(contentsOf: references)
        }

        // Детекция лиц для фото — заранее.
        for slide in references where slide.kind == .photo {
            precomputeFaces(for: slide.id)
        }
    }

    /// Детектирует лица на фото-слайде в фоне и сохраняет результат
    /// в `MediaReference.faceRegions` (кэш, не пересчитывается на экспорте).
    /// - Parameter slideID: id слайда.
    public func precomputeFaces(for slideID: UUID) {
        guard let project = currentProject,
              let slide = project.slides.first(where: { $0.id == slideID }),
              slide.kind == .photo,
              slide.faceRegions.isEmpty else { return }

        let id = slideID
        let reference = slide

        // ВАЖНО: Vision-детекция тяжёлая (для больших фото — секунды/минуты).
        // Выполняем её на фоновом потоке (Task.detached), иначе главный поток
        // блокируется и приложение «зависает» (курсор-крутилка, не открывается
        // NSOpenPanel и т.п.).
        Task.detached(priority: .userInitiated) {
            guard let resolved = try? MediaResolver.resolveWithAccess(reference),
                  let image = CIImage(contentsOf: resolved.url) else { return }
            let regions = (try? await FaceDetector.detectFaces(in: image)) ?? []
            guard !regions.isEmpty else { return }
            await MainActor.run {
                self.updateSlide(id: id) { slide in
                    slide.faceRegions = regions
                }
            }
        }
    }

    /// Переподключает недоступный файл по новому bookmark.
    public func relinkSlide(id: UUID) {
        guard let project = currentProject,
              let index = project.slides.firstIndex(where: { $0.id == id }) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.text(.relinkFile)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { return }

        mutate { project in
            project.slides[index].bookmarkData = bookmark
            project.slides[index].displayName = url.lastPathComponent
        }
    }

    // MARK: - Слайды

    /// Удаляет слайд по id.
    public func removeSlide(id: UUID) {
        mutate { project in
            project.slides.removeAll { $0.id == id }
        }
    }

    /// Перемещает слайд (drag&drop reorder).
    public func moveSlide(from source: Int, to destination: Int) {
        mutate { project in
            project.moveSlide(from: source, to: destination)
        }
    }

    /// Обновляет слайд по id.
    public func updateSlide(id: UUID, _ block: (inout MediaReference) -> Void) {
        mutate { project in
            guard let index = project.slides.firstIndex(where: { $0.id == id }) else { return }
            block(&project.slides[index])
        }
    }
}

/// Помощник импорта медиафайлов: определение типа и Live Photo пары.
public enum MediaImporter {
    /// Разрешённые типы контента.
    public static var allowedContentTypes: [UTType] {
        [
            .jpeg, .heic, .png,                    // фото
            .movie, .mpeg4Movie, .quickTimeMovie,  // видео (mp4, mov)
        ]
    }

    /// Определяет тип медиа по расширению файла.
    public static func mediaKind(for url: URL) -> MediaKind? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "png": return .photo
        case "mov", "mp4", "m4v": return .video
        default: return nil
        }
    }

    /// Live Photo: ищет рядом MOV с тем же базовым именем.
    public static func livePhotoVideoURL(for stillURL: URL) -> URL? {
        let directory = stillURL.deletingLastPathComponent()
        let base = stillURL.deletingPathExtension().lastPathComponent
        let candidate = directory.appendingPathComponent("\(base).mov")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

