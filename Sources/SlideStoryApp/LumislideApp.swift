import SwiftUI

/// Точка входа приложения Lumislide.
@main
struct LumislideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store: ProjectsStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: ProjectsStore(settings: settings))
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

/// Контроллер программного открытия окон (предпросмотр, экспорт, свойства).
@MainActor
public enum AppWindowsController {
    /// Открывает окно предпросмотра проекта.
    public static func openPreview(project: SlideshowProject, store: ProjectsStore) {
        let window = EscCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(L10n.text(.preview)) — \(project.name)"
        // Управляем временем жизни окна вручную: программные NSWindow
        // по умолчанию освобождаются при close(), что вместе с анимацией
        // закрытия даёт EXC_BAD_ACCESS.
        window.isReleasedWhenClosed = false
        // ВАЖНО: не даём NSHostingController сжимать окно под размер контента —
        // иначе окно предпросмотра открывается размером с миниатюру.
        let hosting = NSHostingController(rootView: PreviewWindowView(project: project))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 960, height: 540))
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Открывает окно экспорта проекта.
    public static func openExport(project: SlideshowProject) {
        let window = EscCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(L10n.text(.export)) — \(project.name)"
        window.center()
        window.isReleasedWhenClosed = false
        // ВАЖНО: weak-capture окна — иначе retain cycle
        // window → rootView → onClose → window, что приводит к
        // двойному освобождению (краш) при закрытии окна.
        window.contentViewController = NSHostingController(
            rootView: ExportWindowView(project: project, onClose: { [weak window] in
                window?.close()
            })
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Открывает окно свойств проекта.
    public static func openProperties(project: SlideshowProject, store: ProjectsStore) {
        let window = EscCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(.projectProperties)
        window.center()
        window.isReleasedWhenClosed = false
        // ВАЖНО: weak-capture окна — иначе retain cycle (см. openExport).
        window.contentViewController = NSHostingController(
            rootView: ProjectPropertiesView(project: project, store: store, onClose: { [weak window] in
                window?.close()
            })
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

import AppKit
import SlideStoryModel
