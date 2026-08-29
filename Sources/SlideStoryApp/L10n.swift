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
             relinkFile, hasTitle, transitionLabel, fileNotAvailable, video

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
             timeLeft

        // Настройки
        case settings, projectsFolder, defaultPhotoDuration, autosave, language
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

            .settings: "Settings",
            .projectsFolder: "Projects Folder",
            .defaultPhotoDuration: "Default Photo Duration",
            .autosave: "Autosave Projects",
            .language: "Language",
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

            .settings: "Настройки",
            .projectsFolder: "Папка проектов",
            .defaultPhotoDuration: "Длительность фото по умолчанию",
            .autosave: "Автосохранение проектов",
            .language: "Язык",
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

    /// Локализованные названия 12 типов переходов.
    /// (В модели `TransitionType.displayName` — английские имена для тестов;
    /// UI использует эту таблицу.)
    private static let transitionNames: [AppLanguage: [TransitionType: String]] = [
        .english: [
            .dissolve: "Dissolve",
            .slideLeft: "Slide Left",
            .slideRight: "Slide Right",
            .wipe: "Wipe",
            .push: "Push",
            .irisOpen: "Iris Open",
            .irisClose: "Iris Close",
            .rotateInward: "Rotate Inward",
            .rotateOutward: "Rotate Outward",
            .door: "Door",
            .grid: "Grid",
            .colorFade: "Color Fade",
        ],
        .russian: [
            .dissolve: "Растворение",
            .slideLeft: "Скольжение влево",
            .slideRight: "Скольжение вправо",
            .wipe: "Вытеснение",
            .push: "Сдвиг",
            .irisOpen: "Открытие круга",
            .irisClose: "Закрытие круга",
            .rotateInward: "Вращение внутрь",
            .rotateOutward: "Вращение наружу",
            .door: "Дверь",
            .grid: "Сетка",
            .colorFade: "Цветной fade",
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
}

