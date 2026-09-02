import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO
import CoreTransferable
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

        // По умолчанию проект начинается с Intro (название) и заканчивается
        // Outro («Конец»/«The End») — чёрный фон с титром.
        let name = project.name
        project.slides = Self.makeIntroOutroSlides(projectName: name)

        let store = ProjectStore(fileURL: fileURL)
        try? store.save(project)

        currentProject = project
        currentProjectURL = store.fileURL
        isDirty = false
        reloadProjects()
    }

    /// Автослайды для нового проекта: чёрный фон с титром (Intro — название
    /// проекта, Outro — «Конец»/«The End» по текущему языку интерфейса).
    private static func makeIntroOutroSlides(projectName: String) -> [MediaReference] {
        guard let blackURL = ensureBuiltinBlackImage(),
              let bookmark = try? BookmarkResolver.createBookmark(for: blackURL) else {
            return []
        }
        let endTitle = L10n.currentLanguage == .russian ? "Конец" : "The End"

        func blackSlide(_ text: String) -> MediaReference {
            MediaReference(
                kind: .photo,
                bookmarkData: bookmark,
                displayName: blackURL.lastPathComponent,
                titleOverlay: TitleOverlay(
                    text: text,
                    fontSize: 84,
                    colorRGBA: SIMD4<Double>(1, 1, 1, 1),
                    position: .center
                ),
                isKenBurnsDisabled: true
            )
        }
        return [blackSlide(projectName), blackSlide(endTitle)]
    }

    /// Возвращает URL чёрного PNG (генерирует один раз в Application Support).
    private static func ensureBuiltinBlackImage() -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let directory = base.appendingPathComponent("Lumislide/Builtin", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("black.png")

        guard !fm.fileExists(atPath: url.path) else { return url }

        let size = CGSize(width: 1920, height: 1080)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
              ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
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
        let oldName = project.name
        block(&project)

        // При переименовании проекта синхронизируем титул авто-Intro-слайда:
        // первый чёрный слайд (black.png) с титром, равным старому имени
        // проекта, получает новое имя. Если пользователь вручную изменил
        // титул — не трогаем.
        if project.name != oldName, !project.slides.isEmpty,
           let first = project.slides.first,
           first.kind == .photo,
           first.isKenBurnsDisabled,
           first.displayName.lowercased() == "black.png",
           first.titleOverlay?.text == oldName {
            project.slides[0].titleOverlay?.text = project.name
        }

        project.updatedAt = Date()
        currentProject = project
        isDirty = true
        if settings.autosaveEnabled {
            try? saveCurrentProject()
        }
    }

    // MARK: - Медиа

    /// Добавляет новые слайды в проект, вставляя их ПЕРЕД авто-Outro
    /// (чёрный слайд «Конец»/«The End»), если тот стоит последним.
    /// Если авто-Outro нет или он перемещён — добавляет в конец.
    func insertSlides(_ newSlides: [MediaReference], into project: inout SlideshowProject) {
        guard !newSlides.isEmpty else { return }
        if let outroIndex = Self.autoOutroIndex(in: project) {
            project.slides.insert(contentsOf: newSlides, at: outroIndex)
        } else {
            project.slides.append(contentsOf: newSlides)
        }
    }

    /// Индекс авто-Outro: ПОСЛЕДНИЙ слайд — чёрный фон (black.png)
    /// с титром «Конец»/«The End» и выключенным Ken Burns.
    static func autoOutroIndex(in project: SlideshowProject) -> Int? {
        guard let last = project.slides.last,
              last.kind == .photo,
              last.isKenBurnsDisabled,
              last.displayName.lowercased() == "black.png",
              let text = last.titleOverlay?.text else { return nil }
        let endTitles = ["Конец", "The End"]
        guard endTitles.contains(text) else { return nil }
        return project.slides.count - 1
    }

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
        let urls = panel.urls

        // Создание security-scoped bookmark'ов может заблокироваться на
        // медленных/сетевых томах (и в песочнице) — выполняем в фоне,
        // чтобы главный поток (и UI) не «зависал» после выбора файлов.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let newSlides = Self.makeReferences(from: urls)
            guard !newSlides.isEmpty else { return }
            await MainActor.run {
                self.mutate { project in
                    self.insertSlides(newSlides, into: &project)
                }

                // Детекция лиц для фото — заранее (кэшируется в MediaReference),
                // чтобы Ken Burns учитывал лица при предпросмотре/экспорте.
                for slide in newSlides where slide.kind == .photo {
                    self.precomputeFaces(for: slide.id)
                }
            }
        }
    }

    /// Строит слайды по выбранным URL (bookmarks + Live Photo пары).
    /// Вызывается в фоне — НЕ трогает main-actor state.
    nonisolated private static func makeReferences(from urls: [URL]) -> [MediaReference] {
        var newSlides: [MediaReference] = []
        for url in urls {
            guard let kind = MediaImporter.mediaKind(for: url) else { continue }
            guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { continue }

            // ВАЖНО: свежий bookmark в этой же сессии может не разрешиться
            // (см. BookmarkResolver.registerSessionURL) — регистрируем исходный
            // URL, чтобы миниатюры/предпросмотр читали файл напрямую.
            BookmarkResolver.registerSessionURL(url, forBookmark: bookmark)

            // Live Photo: если выбран HEIC и рядом есть MOV с тем же именем —
            // слайд ведёт себя как видео (движение).
            var refKind = kind
            var bookmarkData = bookmark
            if kind == .photo,
               let videoURL = MediaImporter.livePhotoVideoURL(for: url),
               let videoBookmark = try? BookmarkResolver.createBookmark(for: videoURL) {
                refKind = .video
                bookmarkData = videoBookmark
                BookmarkResolver.registerSessionURL(videoURL, forBookmark: videoBookmark)
            }

            newSlides.append(MediaReference(
                kind: refKind,
                bookmarkData: bookmarkData,
                displayName: url.lastPathComponent
            ))
        }
        return newSlides
    }

    /// Добавляет выбранные элементы медиатеки Фото в конец проекта.
    ///
    /// На macOS системный пикер (PhotosPicker) не отдаёт приложению прямых
    /// ссылок на PHAsset (`itemIdentifier` может быть nil, а медиатека —
    /// недоступна без отдельной авторизации, которую пикер не выдаёт).
    /// Поэтому выбранный контент ИМПОРТИРУЕТСЯ: данные загружаются через
    /// `loadTransferable` и сохраняются в папку приложения
    /// (`Application Support/Lumislide/ImportedMedia`); слайд ссылается на
    /// копию обычным security-scoped bookmark'ом.
    /// - Parameter items: выбранные элементы `PhotosPicker`.
    public func addPhotos(_ items: [PhotosPickerItem]) {
        guard currentProject != nil, !items.isEmpty else { return }

        guard let directory = Self.importedMediaDirectory() else { return }

        for item in items {
            let kind = Self.kind(for: item) ?? .photo
            Task { @MainActor in
                guard self.currentProject != nil,
                      let imported = await Self.importItem(item, kind: kind, into: directory),
                      let bookmark = try? BookmarkResolver.createBookmark(for: imported)
                else { return }

                let reference = MediaReference(
                    kind: kind,
                    bookmarkData: bookmark,
                    displayName: imported.lastPathComponent
                )
                self.mutate { project in
                    self.insertSlides([reference], into: &project)
                }

                // Детекция лиц для фото — заранее.
                if kind == .photo {
                    self.precomputeFaces(for: reference.id)
                }
            }
        }
    }

    /// Тип медиа элемента (по поддерживаемым типам контента).
    private static func kind(for item: PhotosPickerItem) -> MediaKind? {
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .movie) }) { return .video }
        if types.contains(where: { $0.conforms(to: .image) }) { return .photo }
        return nil
    }

    /// Расширение для сохраняемого файла (из типа контента элемента).
    private static func preferredExtension(for item: PhotosPickerItem, kind: MediaKind) -> String {
        let type = item.supportedContentTypes.first { candidate in
            kind == .video ? candidate.conforms(to: .movie) : candidate.conforms(to: .image)
        }
        return type?.preferredFilenameExtension ?? (kind == .video ? "mov" : "jpg")
    }

    /// Папка для импортированного из Фото контента (Application Support).
    private static func importedMediaDirectory() -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let directory = base.appendingPathComponent("Lumislide/ImportedMedia", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Загружает контент элемента и сохраняет его в папку импорта.
    private static func importItem(
        _ item: PhotosPickerItem,
        kind: MediaKind,
        into directory: URL
    ) async -> URL? {
        let ext = preferredExtension(for: item, kind: kind)
        let target = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")

        // Видео предпочитаем загружать файлом — без загрузки всего файла в память.
        if kind == .video, let file = try? await item.loadTransferable(type: PickedMediaFile.self) {
            do {
                try FileManager.default.copyItem(at: file.url, to: target)
                return target
            } catch {
                return nil
            }
        }

        // Универсальный путь: загрузка данных (работает и для фото, и для видео).
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
            try data.write(to: target)
            return target
        } catch {
            return nil
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

        // ВАЖНО: Vision-детекция тяжёлая. Выполняем её строго ПОСЛЕДОВАТЕЛЬНО
        // (одна за другой) на фоновой serial-очереди c низким приоритетом:
        // при добавлении 10+ фото пакет параллельных детекций забивает все
        // ядра на минуты и приложение выглядит «зависшим» (спиннер при любом
        // следующем действии — например, при открытии окна выбора файла).
        // Само изображение декодируется сразу в уменьшенном виде (~1600 px).
        Self.faceDetectionQueue.async { [weak self] in
            guard let resolved = try? MediaResolver.resolveWithAccess(reference) else { return }
            let regions = (try? FaceDetector.detectFacesSync(inImageAt: resolved.url)) ?? []
            guard !regions.isEmpty else { return }
            Task { @MainActor in
                self?.updateSlide(id: id) { slide in
                    slide.faceRegions = regions
                }
            }
        }
    }

    /// Serial-очередь детекции лиц: не больше одной Vision-детекции за раз.
    private static let faceDetectionQueue = DispatchQueue(label: "com.lumislide.face-detection", qos: .utility)

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

        // Создание bookmark в фоне (см. addMedia/chooseMusic) — не блокируем UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { return }
            // Свежий bookmark в текущей сессии (см. registerSessionURL).
            BookmarkResolver.registerSessionURL(url, forBookmark: bookmark)
            let newName = url.lastPathComponent

            await MainActor.run {
                self?.mutate { project in
                    project.slides[index].bookmarkData = bookmark
                    project.slides[index].displayName = newName
                }
            }
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

/// Обёртка для получения файла из PhotosPicker (видео) через `loadTransferable`
/// без загрузки всего содержимого в память.
private struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            PickedMediaFile(url: received.file)
        }
    }
}

