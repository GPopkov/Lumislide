# Техническая документация Lumislide

> **English summary.** Lumislide is a SwiftUI + AppKit macOS app built as three Swift
> Package modules: `SlideStoryModel` (project model, `.slideshow` JSON store,
> security-scoped bookmark resolver), `SlideStoryRenderer` (Ken Burns, CI/Metal
> transitions, video frames, audio mixer, MP4 exporter), `SlideStoryApp` (UI: grid via
> `NSCollectionView`, windows, settings). Projects reference — but never copy — media
> files via bookmarks; the render pipeline decodes photos in an upright
> (EXIF-oriented) space and stores face rectangles in the same space so Ken Burns can
> focus on faces. Everything is deterministic per project seed. Details below in Russian.

---

## 1. Модули

| Модуль | Путь | Назначение |
|---|---|---|
| `SlideStoryModel` | `Sources/SlideStoryModel` | Модель проекта (Codable), файл `.slideshow`, `ProjectStore`, резолвер security-scoped bookmarks, переходы/пропорции/титры — без зависимостей от UI и рендера |
| `SlideStoryRenderer` | `Sources/SlideStoryRenderer` | Рендер-пайплайн: композиция кадра, Ken Burns, переходы (Core Image + Metal), кадры видео, аудио-микшер, экспорт в MP4, детекция лиц (Vision) |
| `SlideStoryApp` | `Sources/SlideStoryApp` | UI: SwiftUI + AppKit (сетка миниатюр на `NSCollectionView`), окна, настройки, локализованное меню, справка |

## 2. Формат проекта (`.slideshow`)

JSON (Codable, `SlideshowProject`). Ключевые поля:

- `name`, `id`, `createdAt`, `updatedAt`, `transitionSeedValue` (64-бит, хранится
  строкой) — детерминизм «случайности»;
- `defaultPhotoDuration`, `transitionDuration`, `isKenBurnsEnabled`;
- `exportSettings` (codec h264/h265, разрешение, fps, качество);
- `aspectRatio` (16:9 / 4:3 / 9:16 / 1:1);
- `music` (источник: пользовательский файл по ссылке или none; громкость);
- `slides: [MediaReference]`.

`MediaReference` хранит: тип (`photo`/`video`), base64 security-scoped bookmark,
отображаемое имя, `titleOverlay`, `isKenBurnsDisabled`, кэш лиц `faceRegions` +
`faceRegionsEpoch`, кэш длительности видео, `photosLocalIdentifier`.

Файл проекта лежит в `~/Lumislide Projects/` (внутри песочницы приложения).
Переименование проекта переименовывает и файл (без перезаписи занятого имени).



## 3. Доступ к медиа (песочница, bookmarks)

Файлы **не копируются** в проект — хранится только ссылка (bookmark). Приложение
работает в песочнице macOS (`com.lumislide.app`).

- Выбор файла через `NSOpenPanel` даёт временный (powerbox) доступ на сессию.
- `BookmarkResolver.createBookmark` создаёт security-scoped bookmark
  (`.withSecurityScope`, read-only), который хранится в проекте и переживает
  перезапуски.
- **Сессионный реестр URL** (`registerSessionURL`): повторное разрешение только что
  созданного bookmark в той же сессии может не сработать/заблокироваться, поэтому
  пока приложение работает, файлы из панели читаются по исходному URL напрямую,
  а bookmark используется в следующих запусках.
- `SecurityScopedAccess` удерживает доступ на время жизни читателя (важно для видео,
  читаемого лениво).
- Контент из медиатеки Фото импортируется копией в `Application Support/Lumislide/`
  (системный пикер не отдаёт ссылок на PHAsset).

## 4. Конвейер рендера

Один кадр (`TimelineFrameRenderer.makeFrame`) = композиция текущего слайда в его
локальном времени (+ переход в зоне перекрытия).

### 4.1 Фото
- Файл декодируется в **upright-пространстве** (`SlideContextFactory.loadUprightPhoto`,
  EXIF-ориентация применена) — единое пространство с детекцией лиц.
- Композиция: `.fit` в холст + размытая фоновая заливка полей; сверху — Ken Burns
  (обрезка/зум всего слоя), затем титр.

### 4.2 Видео
`VideoFrameSource`: `AVAssetImageGenerator` с seek на каждый кадр (известное
ограничение v1). Длительность слайда = реальный диапазон видеодорожки
(не контейнерная), чтобы в «хвосте» не было ошибок кадра.

### 4.3 Ken Burns и координаты (важно)
- Траектория (`KenBurnsTrajectory`) — интерполяция прямоугольника
  `startRect → endRect` в **нормализованных координатах холста**, origin
  **верхний-левый**.
- **Лица** детектятся Vision (`VNDetectFaceRectanglesRequest`, bounding box) на
  upright-изображении, уменьшенном до ~1600 px. Координаты хранятся в модели
  (`faceRegions`) вместе с **эпохой алгоритма** (`faceRegionsEpoch`): старые кэши
  (другие координатные пространства) игнорируются и пересчитываются при открытии
  проекта.
- Перед планировщиком координаты лиц проецируются из пространства изображения в
  пространство холста с учётом aspect-fit полосы (`mapFacesToCanvas`).
- При наличии лиц траектория идёт **от полного кадра к кадру, центрированному на
  объединении лиц** (с запасом ~15%, зум ≤ ~2×); без лиц — правило третей
  (детерминированно по seed, зум 1.0–1.12).
- В компоновщике нормализованные (top-left) прямоугольники переводятся в
  координаты CIImage (origin внизу-слева): **Y инвертируется**.

### 4.4 Переходы
- 8 переходов на Core Image (`blendCoreImage`), 3 — кастомные Metal-кернелы
  (`door`, `gridTransition`, `colorFade`). Шейдеры лежат в
  `Sources/SlideStoryRenderer/Resources/Transitions.metal` и **продублированы**
  встроенной строкой в `TransitionBlender.metalSource` (fallback, если ресурсный
  бандл недоступен в .app). Менять нужно оба места.
- Результат Metal-текстуры возвращается в CI с вертикальным флипом
  (`oriented(.downMirrored)`), регрессия — `MetalTransitionOrientationTests`.
- Переходы детерминированы по `transitionSeedValue` + индексу слайда; override
  слайда — через ПКМ.
- «Дверь» открывается от центра: створки (половины исходного кадра) расходятся
  строго параллельно, без сжатия изображения.



### 4.5 Аудио
`AudioTrackMixer.makeProjectAudioComposition`: музыка на фото-интервалах (fade 2 c
вокруг видео), зацикливание/обрезка под длительность; видео-слайды сохраняют
собственный звук.

## 5. Миниатюры
`ThumbnailCache` (memory NSCache + диск `~/Library/Caches/Lumislide/Thumbnails/`).
Ключ = путь + дата изменения. Миниатюры декодируются **сразу в размере карточки**
(≤512 px), сетка обновляется полным `reloadData` с дебаунсом.

## 6. UI
- Сетка слайдов — `NSCollectionView` (drag&drop reorder) внутри
  `NSViewRepresentable`.
- Вспомогательные окна (Просмотр/Экспорт/Свойства/Справка) — **по одному
  экземпляру** (`AppWindowsController`): повторное открытие активирует окно или
  пересоздаёт контент для другого проекта.
- Главное меню локализуется вручную (`AppMenuController`), т.к. SwiftUI не
  переводит системное меню по переключателю языка. SwiftUI может перезаписать
  `NSApp.mainMenu` своим (англ., без File/Edit) в любой момент — watchdog раз в
  секунду возвращает наше меню.

## 7. Детерминизм
Все «случайные» решения (переходы, направление/масштаб Ken Burns без лиц) выведены
из `transitionSeedValue` и индекса слайда; повторный экспорт неизменённого проекта
даёт идентичный результат.

## 8. Тесты
`swift test`: модель (таймлайн, переходы, Ken Burns, bookmarks, музыка), рендерер
(экспорт, видео-кадры, детекция лиц, ориентация Metal), приложение (локализация,
настройки, импорт, окна).

## 9. Известные ограничения (v1)
- Видео-кадры: `AVAssetImageGenerator` с seek на каждый кадр (план — `AVAssetReader`).
- Blur-фон видео пересчитывается на каждый кадр.
- Встроенной библиотеки музыки нет (только пользовательские файлы).
