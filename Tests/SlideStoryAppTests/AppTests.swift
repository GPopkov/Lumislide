import XCTest
import Foundation
@testable import SlideStoryApp
import SlideStoryModel

final class AppTests: XCTestCase {

    // MARK: - Локализация

    func testEveryKeyHasBothLanguages() {
        for key in L10n.Key.allCases {
            let en = L10n.text(key, language: .english)
            let ru = L10n.text(key, language: .russian)
            XCTAssertFalse(en.isEmpty, "EN перевод пуст для \(key.rawValue)")
            XCTAssertFalse(ru.isEmpty, "RU перевод пуст для \(key.rawValue)")
            // RU всегда должен отличаться от ключа (это настоящий перевод).
            XCTAssertNotEqual(ru, "\(key.rawValue)", "RU перевод не задан для \(key.rawValue)")
        }
    }

    /// Все 12 переходов имеют локализованные названия на обоих языках.
    func testEveryTransitionHasBothLanguages() {
        for type in TransitionType.transitionOrder {
            let en = L10n.transitionName(type, language: .english)
            let ru = L10n.transitionName(type, language: .russian)
            XCTAssertFalse(en.isEmpty, "EN название пусто для \(type.rawValue)")
            XCTAssertFalse(ru.isEmpty, "RU название пусто для \(type.rawValue)")
            // RU — настоящий перевод: должен отличаться от английского.
            XCTAssertNotEqual(ru, en, "RU не переведено для \(type.rawValue)")
        }
        // Точечные проверки.
        XCTAssertEqual(L10n.transitionName(.dissolve, language: .russian), "Растворение")
        XCTAssertEqual(L10n.transitionName(.slideLeft, language: .russian), "Скольжение влево")
        XCTAssertEqual(L10n.transitionName(.push, language: .russian), "Сдвиг влево")
        XCTAssertEqual(L10n.transitionName(.pushRight, language: .russian), "Сдвиг вправо")
        XCTAssertEqual(L10n.transitionName(.dipToBlack, language: .russian), "Затемнение")
        XCTAssertEqual(L10n.transitionName(.door, language: .russian), "Дверь")
        XCTAssertEqual(L10n.transitionName(.grid, language: .russian), "Сетка")
        XCTAssertEqual(L10n.transitionName(.colorFade, language: .russian), "Вспышка")
        XCTAssertEqual(L10n.transitionName(.dissolve, language: .english), "Dissolve")
    }

    func testRussianAndEnglishDiffer() {
        // Как минимум ключи меню должны различаться по языкам.
        XCTAssertNotEqual(
            L10n.text(.addTitle, language: .english),
            L10n.text(.addTitle, language: .russian)
        )
        XCTAssertNotEqual(
            L10n.text(.projectProperties, language: .english),
            L10n.text(.projectProperties, language: .russian)
        )
    }

    func testCurrentLanguageReflectsUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set("ru", forKey: "app.language")
        XCTAssertEqual(L10n.currentLanguage, .russian)
        XCTAssertEqual(L10n.text(.export), "Экспорт")
        // Левая панель главного окна.
        XCTAssertEqual(L10n.text(.projects), "Проекты")
        XCTAssertEqual(L10n.text(.create), "Создать")

        defaults.set("en", forKey: "app.language")
        XCTAssertEqual(L10n.currentLanguage, .english)
        XCTAssertEqual(L10n.text(.export), "Export")
        XCTAssertEqual(L10n.text(.projects), "Projects")
        XCTAssertEqual(L10n.text(.create), "Create")

        // Восстанавливаем разумное значение по умолчанию.
        defaults.removeObject(forKey: "app.language")
    }

    // MARK: - AppSettings

    func testAppSettingsDefaults() {
        let defaults = UserDefaults(suiteName: "test.lumislide.settings")!
        defaults.removePersistentDomain(forName: "test.lumislide.settings")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.autosaveEnabled, true)
        XCTAssertEqual(settings.defaultPhotoDuration, 5.0)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.thumbnailSize, 180.0)

        // Изменение сохраняется в UserDefaults.
        settings.defaultPhotoDuration = 7.0
        settings.autosaveEnabled = false
        settings.language = .russian

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.defaultPhotoDuration, 7.0)
        XCTAssertEqual(reloaded.autosaveEnabled, false)
        XCTAssertEqual(reloaded.language, .russian)

        defaults.removePersistentDomain(forName: "test.lumislide.settings")
    }

    // MARK: - Переименование проекта (проблема 4)

    @MainActor
    func testProjectRenameMovesFileAndReloadsList() throws {
        let defaults = UserDefaults(suiteName: "test.lumislide.rename")!
        defaults.removePersistentDomain(forName: "test.lumislide.rename")
        let settings = AppSettings(defaults: defaults)

        // Временная папка проектов.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        settings.projectsDirectory = dir

        let store = ProjectsStore(settings: settings)
        store.createNewProject()
        let originalURL = store.currentProjectURL
        XCTAssertNotNil(originalURL)
        XCTAssertTrue(fm.fileExists(atPath: originalURL!.path))

        // Переименовываем проект через mutate (как окно свойств).
        store.mutate { project in
            project.name = "My Renamed Project"
        }

        // Файл должен быть переименован на диске.
        let renamedURL = dir.appendingPathComponent("My Renamed Project.slideshow")
        XCTAssertTrue(fm.fileExists(atPath: renamedURL.path), "Файл не переименован")
        XCTAssertFalse(fm.fileExists(atPath: originalURL!.path), "Старый файл остался")
        XCTAssertEqual(store.currentProjectURL, renamedURL)

        // Список проектов обновился.
        // macOS: /var — симлинк на /private/var, поэтому сравниваем
        // стандартизованные URL.
        let standardizedProjects = store.projects.map { $0.standardizedFileURL }
        XCTAssertTrue(standardizedProjects.contains(renamedURL.standardizedFileURL))
        XCTAssertFalse(standardizedProjects.contains(originalURL!.standardizedFileURL))

        defaults.removePersistentDomain(forName: "test.lumislide.rename")
    }

    @MainActor
    func testProjectRenameDoesNotOverwriteExistingFile() throws {
        let defaults = UserDefaults(suiteName: "test.lumislide.rename2")!
        defaults.removePersistentDomain(forName: "test.lumislide.rename2")
        let settings = AppSettings(defaults: defaults)

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        settings.projectsDirectory = dir

        let store = ProjectsStore(settings: settings)
        store.createNewProject()
        let originalURL = store.currentProjectURL!

        // Создаём конфликтующий файл с целевым именем.
        let conflictingURL = dir.appendingPathComponent("Conflict.slideshow")
        try Data("{\"name\":\"Conflict\"}".utf8).write(to: conflictingURL)

        store.mutate { project in
            project.name = "Conflict"
        }

        // Существующий файл не перезаписан; проект остался на старом файле.
        XCTAssertTrue(fm.fileExists(atPath: conflictingURL.path))
        XCTAssertEqual(store.currentProjectURL, originalURL)

        defaults.removePersistentDomain(forName: "test.lumislide.rename2")
    }

    // MARK: - Титул авто-Intro при переименовании

    @MainActor
    func testRenameProjectUpdatesIntroSlideTitle() throws {
        let defaults = UserDefaults(suiteName: "test.lumislide.introTitle")!
        defaults.removePersistentDomain(forName: "test.lumislide.introTitle")
        let settings = AppSettings(defaults: defaults)

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        settings.projectsDirectory = dir

        let store = ProjectsStore(settings: settings)
        store.createNewProject()
        XCTAssertEqual(store.currentProject?.slides.count, 2, "Новый проект должен содержать Intro и Outro")
        XCTAssertEqual(store.currentProject?.slides.first?.titleOverlay?.text, "Untitled")

        // Переименовываем проект — Intro-слайд должен получить новое имя.
        store.mutate { project in
            project.name = "Светлогорск 2026"
        }
        XCTAssertEqual(store.currentProject?.slides.first?.titleOverlay?.text, "Светлогорск 2026",
                       "Титул Intro-слайда должен следовать за именем проекта")

        // Outro не должен измениться.
        let outro = store.currentProject?.slides.last?.titleOverlay?.text
        XCTAssertNotEqual(outro, "Светлогорск 2026")

        defaults.removePersistentDomain(forName: "test.lumislide.introTitle")
    }

    @MainActor
    func testRenameProjectDoesNotTouchManualIntroTitle() throws {
        let defaults = UserDefaults(suiteName: "test.lumislide.introTitle2")!
        defaults.removePersistentDomain(forName: "test.lumislide.introTitle2")
        let settings = AppSettings(defaults: defaults)

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        settings.projectsDirectory = dir

        let store = ProjectsStore(settings: settings)
        store.createNewProject()

        // Пользователь вручную поменял титул Intro.
        store.updateSlide(id: store.currentProject!.slides[0].id) { slide in
            slide.titleOverlay?.text = "Мой фильм"
        }

        store.mutate { project in
            project.name = "Другое имя"
        }
        XCTAssertEqual(store.currentProject?.slides.first?.titleOverlay?.text, "Мой фильм",
                       "Вручную изменённый титул не должен перезаписываться")

        defaults.removePersistentDomain(forName: "test.lumislide.introTitle2")
    }

    @MainActor
    func testInsertSlidesGoesBeforeAutoOutro() throws {
        let defaults = UserDefaults(suiteName: "test.lumislide.insertOrder")!
        defaults.removePersistentDomain(forName: "test.lumislide.insertOrder")
        let settings = AppSettings(defaults: defaults)
        let store = ProjectsStore(settings: settings)

        func blackSlide(_ text: String) -> MediaReference {
            MediaReference(
                kind: .photo,
                bookmarkData: "bm-black",
                displayName: "black.png",
                titleOverlay: TitleOverlay(text: text, fontSize: 84, colorRGBA: .init(1, 1, 1, 1), position: .center),
                isKenBurnsDisabled: true
            )
        }

        // Порядок в новом проекте: Intro, Outro; медиа должны встать между ними.
        var project = SlideshowProject(name: "Test")
        project.slides = [blackSlide("Intro"), blackSlide("Конец")]

        let photo = MediaReference(kind: .photo, bookmarkData: "bm-photo", displayName: "photo.jpg")
        let video = MediaReference(kind: .video, bookmarkData: "bm-video", displayName: "clip.mp4")
        store.insertSlides([photo, video], into: &project)

        XCTAssertEqual(
            project.slides.map(\.displayName),
            ["black.png", "photo.jpg", "clip.mp4", "black.png"],
            "Медиа должны вставляться перед авто-Outro"
        )

        // Если авто-Outro отсутствует — обычное добавление в конец.
        var project2 = SlideshowProject(name: "No Outro")
        project2.slides = [blackSlide("Intro")]
        store.insertSlides([photo], into: &project2)
        XCTAssertEqual(project2.slides.map(\.displayName), ["black.png", "photo.jpg"])

        defaults.removePersistentDomain(forName: "test.lumislide.insertOrder")
    }

    // MARK: - MediaImporter

    func testMediaKindDetection() {
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.jpg")), .photo)
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.heic")), .photo)
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.png")), .photo)
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.mov")), .video)
        XCTAssertEqual(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.mp4")), .video)
        XCTAssertNil(MediaImporter.mediaKind(for: URL(fileURLWithPath: "/tmp/a.txt")))
    }

    func testLivePhotoVideoURL() {
        // Пары не существует — должен вернуть nil.
        let still = URL(fileURLWithPath: "/tmp/IMG_0001.heic")
        XCTAssertNil(MediaImporter.livePhotoVideoURL(for: still))
    }
}
