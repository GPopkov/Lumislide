import SwiftUI

/// Точка входа приложения Lumislide.
@main
struct LumislideApp: App {
    @NSApplicationDelegateAdaptor(LumislideAppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var store: ProjectsStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: ProjectsStore(settings: settings))
        // Кастомное локализуемое главное меню (устанавливается после запуска).
        AppMenuController.shared.configure(store: _store.wrappedValue, settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(settings)
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // Настройки приложения.
        Settings {
            SettingsView()
                .environmentObject(settings)
        }

        // Вторичные окна открываются программно (см. AppWindowsController).
    }
}

/// Устанавливает кастомное локализуемое меню после запуска приложения.
@MainActor
final class LumislideAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        case preview, export, properties, help
    }

    /// Открытые окна (сильная ссылка; очищается при закрытии окна).
    private static var windows: [Kind: NSWindow] = [:]
    /// id проекта, для которого открыто окно (preview/export/properties).
    private static var projectIDs: [Kind: UUID] = [:]
    private static var closeObservers: [Kind: NSObjectProtocol] = [:]

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
