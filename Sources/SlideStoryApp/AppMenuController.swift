import AppKit
import Combine

/// Построитель локализованного главного меню приложения.
///
/// macOS не переводит системное меню SwiftUI-приложения по переключателю
/// языка внутри приложения, поэтому меню строится вручную и пересобирается
/// при смене `AppSettings.language`.
@MainActor
final class AppMenuController: NSObject {
    static let shared = AppMenuController()

    weak var store: ProjectsStore?
    weak var settings: AppSettings?
    private var cancellable: AnyCancellable?
    private var builtLanguage: AppLanguage?
    /// Последнее установленное нами меню (для защиты от перезаписи SwiftUI).
    private var currentMainMenu: NSMenu?
    private var observers: [NSObjectProtocol] = []
    /// Watchdog: SwiftUI может перезаписать mainMenu в ЛЮБОЙ момент (не только
    /// при запуске) — периодически возвращаем своё меню.
    private var watchdog: Timer?

    /// Подключает store/settings и подписывается на смену языка.
    /// Меню устанавливается в `install()` (после запуска NSApplication).
    func configure(store: ProjectsStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        cancellable = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.settings?.language else { return }
                // Пересобираем меню только при реальной смене языка.
                if current != self.builtLanguage {
                    self.builtLanguage = current
                    self.rebuild()
                }
            }
        }
    }

    /// Устанавливает меню (вызывается после запуска приложения).
    func install() {
        builtLanguage = settings?.language
        rebuild()

        // ВАЖНО: SwiftUI (App-жизненный цикл) может установить СВОЙ
        // (английский) mainMenu ПОСЛЕ нашего applicationDidFinishLaunching —
        // гонка, из-за которой русское меню иногда пропадает, а File/Edit
        // исчезают. Защищаемся: возвращаем своё меню в течение первой
        // секунды и при каждой активации/фокусе окна.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                // Переустановка — следующим проходом run loop, ПОСЛЕ обработчиков
                // SwiftUI того же события (иначе SwiftUI успевает мутировать меню).
                DispatchQueue.main.async { self?.assertOwnMenu() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                               object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.assertOwnMenu() }
            },
        ]
        for delay in [0.1, 0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.assertOwnMenu()
            }
        }

        // Постоянный «сторожевой» таймер: SwiftUI может мутировать/подменять
        // mainMenu в любой момент (смена сцены, активация, открытие окна) —
        // раз в секунду сверяем состав и возвращаем своё меню.
        let watchdog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.assertOwnMenu()
        }
        watchdog.tolerance = 0.2
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    /// Если mainMenu сейчас НЕ наш (SwiftUI мутирует пункты нашего меню или
    /// подменяет сам объект) — возвращаем своё меню.
    private func assertOwnMenu() {
        let current = NSApp.mainMenu
        if current !== currentMainMenu {
            rebuild()
            return
        }
        // SwiftUI часто НЕ заменяет NSApp.mainMenu, а редактирует его пункты
        // (оставляя Lumislide/View/Window/Help и убирая File/Edit) — поэтому
        // сравниваем состав верхнего уровня с ожидаемым.
        guard let expected = expectedTopLevelTitles() else { return }
        let actual = (current?.items ?? []).compactMap { $0.submenu?.title ?? $0.title }
        if actual != expected {
            rebuild()
        }
    }

    /// Ожидаемый состав верхнего уровня меню для текущего языка.
    private func expectedTopLevelTitles() -> [String]? {
        guard let builtLanguage else { return nil }
        return [
            "Lumislide",
            L10n.text(.fileMenu, language: builtLanguage),
            L10n.text(.editMenu, language: builtLanguage),
            L10n.text(.viewMenu, language: builtLanguage),
            L10n.text(.windowMenu, language: builtLanguage),
            L10n.text(.help, language: builtLanguage),
        ]
    }

    func rebuild() {
        let menu = buildMainMenu()
        currentMainMenu = menu
        NSApp.mainMenu = menu
    }

    // MARK: - Меню

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu()
        appItem.submenu?.title = "Lumislide"
        mainMenu.addItem(appItem)

        mainMenu.addItem(topLevel(L10n.text(.fileMenu), fileMenu()))
        mainMenu.addItem(topLevel(L10n.text(.editMenu), editMenu()))
        mainMenu.addItem(topLevel(L10n.text(.viewMenu), viewMenu()))
        mainMenu.addItem(topLevel(L10n.text(.windowMenu), windowMenu()))
        mainMenu.addItem(topLevel(L10n.text(.help), helpMenu()))
        return mainMenu
    }

    private func topLevel(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = submenu
        item.submenu?.title = title
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L10n.text(.about), #selector(showAbout), self)
        menu.addItem(.separator())
        add(menu, L10n.text(.settings), #selector(showSettings), self, ",")
        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: L10n.text(.services), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L10n.text(.services))
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        menu.addItem(.separator())
        add(menu, L10n.text(.hide), #selector(hideApp), self, "h")
        let hideOthers = NSMenuItem(title: L10n.text(.hideOthers), action: #selector(hideOthersApp), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = self
        menu.addItem(hideOthers)
        add(menu, L10n.text(.showAll), #selector(showAllApp), self)
        menu.addItem(.separator())
        add(menu, L10n.text(.quit), #selector(quitApp), self, "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L10n.text(.newProject), #selector(newProject), self, "n")
        add(menu, L10n.text(.addMedia), #selector(addMedia), self)
        menu.addItem(.separator())
        add(menu, L10n.text(.projectProperties), #selector(openProperties), self)
        add(menu, L10n.text(.preview), #selector(openPreview), self)
        add(menu, L10n.text(.export), #selector(openExport), self)
        menu.addItem(.separator())
        add(menu, L10n.text(.closeWindow), Selector(("performClose:")), nil, "w")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L10n.text(.undo), Selector(("undo:")), nil, "z")
        let redo = NSMenuItem(title: L10n.text(.redo), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        add(menu, L10n.text(.cut), Selector(("cut:")), nil, "x")
        add(menu, L10n.text(.copy), Selector(("copy:")), nil, "c")
        add(menu, L10n.text(.paste), Selector(("paste:")), nil, "v")
        add(menu, L10n.text(.selectAll), Selector(("selectAll:")), nil, "a")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        let fullScreen = NSMenuItem(title: L10n.text(.toggleFullScreen),
                                    action: Selector(("toggleFullScreen:")), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L10n.text(.minimize), Selector(("performMiniaturize:")), nil, "m")
        add(menu, L10n.text(.zoom), Selector(("performZoom:")), nil)
        menu.addItem(.separator())
        add(menu, L10n.text(.bringAllToFront), Selector(("arrangeInFront:")), nil)
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L10n.text(.lumislideHelp), #selector(openHelp), self)
        return menu
    }

    // MARK: - Хелпер

    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ target: AnyObject?,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = target
        menu.addItem(item)
    }

    // MARK: - Действия

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func hideApp() { NSApp.hide(nil) }
    @objc private func hideOthersApp() { NSApp.hideOtherApplications(nil) }
    @objc private func showAllApp() { NSApp.unhideAllApplications(nil) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func newProject() { store?.createNewProject() }
    @objc private func addMedia() { store?.addMedia() }

    @objc private func openProperties() {
        guard let store, let project = store.currentProject else { return }
        AppWindowsController.openProperties(project: project, store: store)
    }

    @objc private func openPreview() {
        guard let store, let project = store.currentProject else { return }
        AppWindowsController.openPreview(project: project, store: store)
    }

    @objc private func openExport() {
        guard let store, let project = store.currentProject else { return }
        AppWindowsController.openExport(project: project)
    }

    @objc private func openHelp() {
        AppWindowsController.openHelp()
    }
}
