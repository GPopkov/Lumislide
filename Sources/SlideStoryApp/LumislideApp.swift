import SwiftUI

/// Точка входа приложения Lumislide.
@main
struct LumislideApp: App {
    @NSApplicationDelegateAdaptor(LumislideAppDelegate.self) private var appDelegate

    // ВАЖНО: используем синглтоны, а не @StateObject, создаваемый в init().
    // `_store.wrappedValue` в init() создаёт ВРЕМЕННЫЙ экземпляр (SwiftUI затем
    // инсталлирует StateObject заново) — переданный в AppMenuController store
    // деаллоцировался, и все пункты меню, зависящие от store, не работали.
    private let settings = AppSettings.shared
    private let store = ProjectsStore.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(settings)
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // Вторичные окна (в т.ч. Настройки) открываются программно и
        // управляются AppWindowsController — см. AppWindowsController.openSettings.
    }
}

/// Устанавливает кастомное локализуемое меню после запуска приложения.
@MainActor
final class LumislideAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Меню подключаем здесь (ровно один раз после запуска) с общими
        // синглтонами — так AppMenuController.store всегда валиден.
        AppMenuController.shared.configure(store: ProjectsStore.shared, settings: AppSettings.shared)
        AppMenuController.shared.install()
    }
}

/// Контроллер программного открытия окон (предпросмотр, экспорт, свойства, справка).
///
/// Каждое окно существует в ОДНОМ экземпляре: повторный вызов открытия
/// активирует уже открытое окно (а если оно открыто для другого проекта —
/// пересоздаёт контент под актуальный проект).
@MainActor
public enum AppWindowsController {
    private enum Kind: Hashable {
        case preview, export, properties, help, settings, slideViewer
    }

    /// Открытые окна (сильная ссылка; очищается при закрытии окна).
    private static var windows: [Kind: NSWindow] = [:]
    /// id проекта, для которого открыто окно (preview/export/properties).
    private static var projectIDs: [Kind: UUID] = [:]
    private static var closeObservers: [Kind: NSObjectProtocol] = [:]
    /// Модель окна увеличенного просмотра слайда (единственный экземпляр).
    private static var slideViewerModel: SlideViewerModel?

    /// Открывает окно предпросмотра проекта.
    public static func openPreview(project: SlideshowProject, store: ProjectsStore) {
        show(.preview, projectID: project.id) {
            let window = EscCloseWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(L10n.text(.preview)) — \(project.name)"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: PreviewWindowView(project: project))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 960, height: 540))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.center()
            return window
        }
    }

    /// Открывает окно экспорта проекта.
    public static func openExport(project: SlideshowProject) {
        show(.export, projectID: project.id) {
            let window = EscCloseWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(L10n.text(.export)) — \(project.name)"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ExportWindowView(project: project, onClose: { [weak window] in
                    window?.close()
                })
            )
            return window
        }
    }
    /// Открывает окно свойств проекта.
    public static func openProperties(project: SlideshowProject, store: ProjectsStore) {
        show(.properties, projectID: project.id) {
            let window = EscCloseWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text(.projectProperties)
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ProjectPropertiesView(project: project, store: store, onClose: { [weak window] in
                    window?.close()
                })
            )
            return window
        }
    }

    /// Открывает окно справки.
    public static func openHelp() {
        show(.help, projectID: nil) {
            let window = EscCloseWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text(.lumislideHelp)
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HelpWindowView())
            return window
        }
    }

    /// Открывает окно настроек приложения.
    ///
    /// ВАЖНО: НЕ используем SwiftUI-сцену `Settings` и `showSettingsWindow:`
    /// через responder chain — из-за кастомного @NSApplicationDelegateAdaptor
    /// это действие не доходит до обработчика SwiftUI. Открываем своё окно
    /// (как остальные вторичные окна приложения).
    public static func openSettings(settings: AppSettings) {
        show(.settings, projectID: nil) {
            let window = EscCloseWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text(.settings)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView().environmentObject(settings)
            )
            window.setFrameAutosaveName("SettingsWindow")
            window.center()
            return window
        }
    }

    /// Открывает окно увеличенного просмотра слайда (двойной щелчок по карточке).
    /// Повторный вызов активирует открытое окно и переходит к выбранному слайду.
    public static func openSlideViewer(store: ProjectsStore, startIndex: Int) {
        if let model = slideViewerModel, let window = windows[.slideViewer] {
            model.setIndex(startIndex)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = SlideViewerModel(store: store, startIndex: startIndex)
        slideViewerModel = model
        show(.slideViewer, projectID: store.currentProject?.id) {
            let window = SlideViewerWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text(.slideViewer)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 340)
            let hosting = NSHostingController(rootView: SlideViewerWindowView(model: model))
            // Без этого SwiftUI ужимает окно до минимального размера контента.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 960, height: 680))
            window.setFrameAutosaveName("SlideViewerWindow")
            window.center()
            window.onKeyDown = { [weak model, weak window] keyCode in
                guard let model else { return false }
                switch keyCode {
                case 123, 126: model.previous(); return true   // ← ↑
                case 124, 125: model.next(); return true        // → ↓
                case 115: model.showFirst(); return true        // Home
                case 119: model.showLast(); return true         // End
                case 53: window?.performClose(nil); return true // Esc
                default: return false
                }
            }
            return window
        }
    }

    // MARK: - Единый экземпляр окна

    /// Показывает окно нужного типа. Если окно уже открыто для того же
    /// проекта — просто активирует его; для другого проекта — пересоздаёт.
    private static func show(_ kind: Kind, projectID: UUID?, make: () -> NSWindow) {
        if let existing = windows[kind] {
            if projectID == nil || projectIDs[kind] == projectID {
                if existing.isMiniaturized { existing.deminiaturize(nil) }
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if let token = closeObservers[kind] {
                NotificationCenter.default.removeObserver(token)
                closeObservers[kind] = nil
            }
            windows[kind]?.close()
            windows[kind] = nil
            projectIDs[kind] = nil
        }

        let window = make()
        windows[kind] = window
        projectIDs[kind] = projectID
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                windows[kind] = nil
                projectIDs[kind] = nil
                if kind == .slideViewer {
                    slideViewerModel = nil
                }
                if let observer = closeObservers[kind] {
                    NotificationCenter.default.removeObserver(observer)
                    closeObservers[kind] = nil
                }
            }
        }
        closeObservers[kind] = token
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
import AppKit
import SlideStoryModel
