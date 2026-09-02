import Foundation
import SlideStoryModel

/// Локализация строк интерфейса (en/ru).
///
/// Механизм: ключ → перевод в словаре текущего языка. Язык выбирается
/// в настройках приложения (`AppSettings.language`). Значения читаются
/// из UserDefaults напрямую, поэтому работают без environmentObject.
public enum L10n {

    // MARK: - Ключи

    public enum Key: String, CaseIterable {
        // Главное окно
        case projects, noProjectSelected, noProjectsYet, clickPlusToCreate,
             addMedia, properties, preview, export, createNewProject, create,
             chooseFolder, open, delete

        // Сетка / карточки
        case automaticRandom, forceTransition, addTitle, disableKenBurns,
             relinkFile, hasTitle, transitionLabel, fileNotAvailable, video,
             thumbnailSize, fromPhotos

        // Свойства проекта
        case projectProperties, name, photoDuration, transitionDuration,
             kenBurnsEffect, aspectRatio, backgroundMusic, chooseAudioFile,
             removeMusic, volume, musicPlaysOnlyDuringPhotos, close, cancel, save

        // Титры
        case title, text, fontSize, color, position, top, center, bottom

        // Предпросмотр
        case preparing

        // Экспорт
        case codec, resolution, frameRate, quality, ready, exporting,
             exportFinished, exportCancelled, exportFailed, cancelExport,
             timeLeft, estimatedFileSize, approxMB, approxGB, done

        // Настройки
        case settings, projectsFolder, defaultPhotoDuration, autosave, language

        // Справка / меню
        case help, lumislideHelp,
             newProject, closeWindow, about, quit, hide, hideOthers, showAll, services,
             undo, redo, cut, copy, paste, selectAll, minimize, zoom, bringAllToFront,
             toggleFullScreen, fileMenu, editMenu, viewMenu, windowMenu
    }

    // MARK: - Переводы

    private static let table: [AppLanguage: [Key: String]] = [
        .english: [
            .projects: "Projects",
            .noProjectSelected: "No Project Selected",
            .noProjectsYet: "No projects yet",
            .clickPlusToCreate: "Click + to create one",
            .addMedia: "Add Media",
            .properties: "Properties",
            .preview: "Preview",
            .export: "Export",
            .createNewProject: "Create New Project",
            .create: "Create",
            .chooseFolder: "Choose…",
            .open: "Open",
            .delete: "Delete",

            .automaticRandom: "Automatic (Random)",
            .forceTransition: "Force Transition",
            .addTitle: "Add Title…",
            .disableKenBurns: "Disable Ken Burns on This Photo",
            .relinkFile: "Relink File…",
            .hasTitle: "Has title",
            .transitionLabel: "Transition",
            .fileNotAvailable: "File not available — right-click to relink",
            .video: "video",
            .thumbnailSize: "Thumbnail Size",
            .fromPhotos: "From Photos Library",

            .projectProperties: "Project Properties",
            .name: "Name",
            .photoDuration: "Photo Duration",
            .transitionDuration: "Transition Duration",
            .kenBurnsEffect: "Ken Burns Effect",
            .aspectRatio: "Aspect Ratio",
            .backgroundMusic: "Background Music",
            .chooseAudioFile: "Choose Audio File…",
            .removeMusic: "Remove Music",
            .volume: "Volume",
            .musicPlaysOnlyDuringPhotos: "Music plays only during photo slides (2 s fade around videos).",
            .close: "Close",
            .cancel: "Cancel",
            .save: "Save",

            .title: "Title",
            .text: "Text",
            .fontSize: "Font Size",
            .color: "Color",
            .position: "Position",
            .top: "Top",
            .center: "Center",
            .bottom: "Bottom",

            .preparing: "Preparing…",

            .codec: "Codec",
            .resolution: "Resolution",
            .frameRate: "Frame Rate",
            .quality: "Quality",
            .ready: "Ready",
            .exporting: "Exporting…",
            .exportFinished: "Export finished.",
            .exportCancelled: "Export cancelled.",
            .exportFailed: "Export failed.",
            .cancelExport: "Cancel Export",
            .timeLeft: "s left",
            .estimatedFileSize: "Estimated File Size",
            .approxMB: "≈ %@ MB",
            .approxGB: "≈ %@ GB",
            .done: "Done",

            .settings: "Settings",
            .projectsFolder: "Projects Folder",
            .defaultPhotoDuration: "Default Photo Duration",
            .autosave: "Autosave Projects",
            .language: "Language",

            .help: "Help",
            .lumislideHelp: "Lumislide Help",
            .newProject: "New Project",
            .closeWindow: "Close Window",
            .about: "About Lumislide",
            .quit: "Quit Lumislide",
            .hide: "Hide Lumislide",
            .hideOthers: "Hide Others",
            .showAll: "Show All",
            .services: "Services",
            .undo: "Undo",
            .redo: "Redo",
            .cut: "Cut",
            .copy: "Copy",
            .paste: "Paste",
            .selectAll: "Select All",
            .minimize: "Minimize",
            .zoom: "Zoom",
            .bringAllToFront: "Bring All to Front",
            .toggleFullScreen: "Enter Full Screen",
            .fileMenu: "File",
            .editMenu: "Edit",
            .viewMenu: "View",
            .windowMenu: "Window",
        ],
        .russian: [
            .projects: "Проекты",
            .noProjectSelected: "Проект не выбран",
            .noProjectsYet: "Проектов пока нет",
            .clickPlusToCreate: "Нажмите +, чтобы создать",
            .addMedia: "Добавить медиа",
            .properties: "Свойства",
            .preview: "Просмотр",
            .export: "Экспорт",
            .createNewProject: "Создать новый проект",
            .create: "Создать",
            .chooseFolder: "Выбрать…",
            .open: "Открыть",
            .delete: "Удалить",

            .automaticRandom: "Автоматически (случайно)",
            .forceTransition: "Принудительный переход",
            .addTitle: "Добавить титр…",
            .disableKenBurns: "Выключить эффект Кена Бёрнса",
            .relinkFile: "Переподключить файл…",
            .hasTitle: "Есть титр",
            .transitionLabel: "Переход",
            .fileNotAvailable: "Файл недоступен — ПКМ, чтобы переподключить",
            .video: "видео",
            .thumbnailSize: "Размер миниатюр",
            .fromPhotos: "Из медиатеки Фото",

            .projectProperties: "Свойства проекта",
            .name: "Название",
            .photoDuration: "Длительность фото",
            .transitionDuration: "Длительность переходов",
            .kenBurnsEffect: "Эффект Кена Бёрнса",
            .aspectRatio: "Соотношение сторон",
            .backgroundMusic: "Фоновая музыка",
            .chooseAudioFile: "Выбрать аудиофайл…",
            .removeMusic: "Убрать музыку",
            .volume: "Громкость",
            .musicPlaysOnlyDuringPhotos: "Музыка звучит только на фото-слайдах (fade 2 c вокруг видео).",
            .close: "Закрыть",
            .cancel: "Отмена",
            .save: "Сохранить",

            .title: "Титр",
            .text: "Текст",
            .fontSize: "Размер шрифта",
            .color: "Цвет",
            .position: "Позиция",
            .top: "Сверху",
            .center: "По центру",
            .bottom: "Снизу",

            .preparing: "Подготовка…",

            .codec: "Кодек",
            .resolution: "Разрешение",
            .frameRate: "Частота кадров",
            .quality: "Качество",
            .ready: "Готово",
            .exporting: "Экспорт…",
            .exportFinished: "Экспорт завершён.",
            .exportCancelled: "Экспорт отменён.",
            .exportFailed: "Экспорт не удался.",
            .cancelExport: "Отменить экспорт",
            .timeLeft: "с осталось",
            .estimatedFileSize: "Примерный размер файла",
            .approxMB: "≈ %@ МБ",
            .approxGB: "≈ %@ ГБ",
            .done: "Готово",

            .settings: "Настройки",
            .projectsFolder: "Папка проектов",
            .defaultPhotoDuration: "Длительность фото по умолчанию",
            .autosave: "Автосохранение проектов",
            .language: "Язык",

            .help: "Справка",
            .lumislideHelp: "Справка Lumislide",
            .newProject: "Новый проект",
            .closeWindow: "Закрыть окно",
            .about: "О программе Lumislide",
            .quit: "Завершить Lumislide",
            .hide: "Скрыть Lumislide",
            .hideOthers: "Скрыть остальные",
            .showAll: "Показать все",
            .services: "Службы",
            .undo: "Отменить",
            .redo: "Повторить",
            .cut: "Вырезать",
            .copy: "Копировать",
            .paste: "Вставить",
            .selectAll: "Выбрать всё",
            .minimize: "Свернуть",
            .zoom: "Масштаб",
            .bringAllToFront: "На передний план все",
            .toggleFullScreen: "Во весь экран",
            .fileMenu: "Файл",
            .editMenu: "Правка",
            .viewMenu: "Вид",
            .windowMenu: "Окно",
        ],
    ]

    // MARK: - API

    /// Текущий язык из UserDefaults (без environmentObject).
    public static var currentLanguage: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "en") ?? .english
    }

    /// Перевод строки по ключу на текущем языке.
    public static func text(_ key: Key) -> String {
        table[currentLanguage]?[key] ?? table[.english]?[key] ?? key.rawValue
    }

    /// Перевод строки по ключу на указанном языке.
    public static func text(_ key: Key, language: AppLanguage) -> String {
        table[language]?[key] ?? table[.english]?[key] ?? key.rawValue
    }

    // MARK: - Названия переходов

    /// Локализованные названия типов переходов.
    /// (В модели `TransitionType.displayName` — английские имена для тестов;
    /// UI использует эту таблицу.)
    private static let transitionNames: [AppLanguage: [TransitionType: String]] = [
        .english: [
            .dissolve: "Dissolve",
            .slideLeft: "Slide Left",
            .slideRight: "Slide Right",
            .push: "Push Left",
            .pushRight: "Push Right",
            .irisOpen: "Iris Open",
            .irisClose: "Iris Close",
            .dipToBlack: "Dip to Black",
            .door: "Door",
            .grid: "Grid",
            .colorFade: "Flash",
        ],
        .russian: [
            .dissolve: "Растворение",
            .slideLeft: "Скольжение влево",
            .slideRight: "Скольжение вправо",
            .push: "Сдвиг влево",
            .pushRight: "Сдвиг вправо",
            .irisOpen: "Открытие круга",
            .irisClose: "Закрытие круга",
            .dipToBlack: "Затемнение",
            .door: "Дверь",
            .grid: "Сетка",
            .colorFade: "Вспышка",
        ],
    ]

    /// Локализованное название перехода на текущем языке.
    public static func transitionName(_ type: TransitionType) -> String {
        transitionName(type, language: currentLanguage)
    }

    /// Локализованное название перехода на указанном языке.
    public static func transitionName(_ type: TransitionType, language: AppLanguage) -> String {
        transitionNames[language]?[type] ?? type.displayName
    }

    // MARK: - Справка

    /// Раздел справки: заголовок + текст.
    public struct HelpSection {
        public let title: String
        public let body: String
        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Содержимое окна справки на текущем языке.
    public static func helpSections() -> [HelpSection] {
        switch currentLanguage {
        case .russian:
            return [
                HelpSection(title: "Добавление медиа",
                            body: "Нажмите «Добавить медиа» в тулбаре и выберите файлы (JPEG/HEIC/PNG, MOV/MP4) или «Из медиатеки Фото», чтобы добавить фото и видео из приложения «Фото»."),
                HelpSection(title: "Порядок слайдов",
                            body: "Перетаскивайте карточки в сетке — порядок карточек равен порядку в итоговом видео. Новый проект уже содержит Intro (название) и Outro («Конец») на чёрном фоне."),
                HelpSection(title: "Переходы",
                            body: "Переходы назначаются автоматически и детерминированно (повторный экспорт даёт тот же результат). Чтобы задать конкретный переход, кликните по карточке правой кнопкой → «Принудительный переход»; оранжевый чип показывает выбранный переход."),
                HelpSection(title: "Титры",
                            body: "ПКМ по фото → «Добавить титр…»: текст, размер шрифта, цвет и позиция (сверху/по центру/снизу)."),
                HelpSection(title: "Эффект Кена Бёрнса и лица",
                            body: "К фото автоматически применяется медленный зум/панорама, точка интереса учитывает найденные лица. Отключить для слайда: ПКМ → «Выключить эффект Кена Бёрнса»."),
                HelpSection(title: "Музыка",
                            body: "В «Свойствах проекта» подключите аудиофайл по ссылке. Музыка звучит только на фото-слайдах (с fade вокруг видео); на видео-слайдах звучит собственная звуковая дорожка."),
                HelpSection(title: "Предпросмотр и экспорт",
                            body: "«Предпросмотр» — живой рендер (play/pause, перемотка, громкость). «Экспорт» — H.264/H.265 в MP4 с выбором разрешения, качества и оценкой размера файла. Окна закрываются по Esc."),
            ]
        case .english:
            return [
                HelpSection(title: "Adding media",
                            body: "Click 'Add Media' in the toolbar and choose files (JPEG/HEIC/PNG, MOV/MP4), or use 'From Photos Library' to add photos and videos from the Photos app."),
                HelpSection(title: "Slide order",
                            body: "Drag the cards in the grid — the card order equals the order in the final video. A new project already includes an intro (project name) and outro ('The End') on a black background."),
                HelpSection(title: "Transitions",
                            body: "Transitions are applied automatically and deterministically (re-exporting yields the same result). To force one, right-click a card → 'Force Transition'; an orange chip shows the chosen transition."),
                HelpSection(title: "Titles",
                            body: "Right-click a photo → 'Add Title…': text, font size, color and position (top/center/bottom)."),
                HelpSection(title: "Ken Burns effect & faces",
                            body: "Photos get a slow zoom/pan automatically; the focus point accounts for detected faces. Disable per slide: right-click → 'Disable Ken Burns on This Photo'."),
                HelpSection(title: "Music",
                            body: "Attach an audio file by reference in 'Project Properties'. Music plays only during photo slides (with fades around videos); video slides keep their own audio track."),
                HelpSection(title: "Preview & export",
                            body: "'Preview' renders live (play/pause, scrubbing, volume). 'Export' produces H.264/H.265 MP4 with resolution, quality and an estimated file size. Windows close with Esc."),
            ]
        }
    }
}

