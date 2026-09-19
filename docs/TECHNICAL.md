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
- `music` (источник: плейлист пользовательских файлов или none; громкость,
  ducking);
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
- «Скольжение влево/вправо» реализовано явной трансляцией (следующий слайд
  въезжает поверх статичного предыдущего). Ранее использовался
  `CISwipeTransition` с `width = 0`: его геометрия вырождалась и зависела от
  размера холста, из-за чего в экспортированном фильме эффект заканчивался
  примерно за 20% времени перехода. Регрессия —
  `testSlideTransitionProgressIsGradualAtAnyCanvasSize`.
- Экспорт рендерит кадр в CVPixelBuffer с ЯВНЫМИ bounds и цветовым
  пространством (`ciContext.render(_:to:bounds:colorSpace:)`) — иначе при
  несовпадении extent кадра и холста получался смещённый кадр.



### 4.5 Аудио
`AudioTrackMixer.makeProjectAudioComposition`: музыка на фото-интервалах (fade 1 c
вокруг видео), **плейлист из нескольких треков** проигрывается последовательно по
кругу; при включённом ducking музыка дополнительно звучит на видео-интервалах с
приглушённой громкостью (`MusicSettings.duckingLevel`); видео-слайды сохраняют
собственный звук. Источник — `MusicSource.userFiles([MediaAudioReference])`
(обратносовместим с одиночным `userFile`).

### 4.6 Производительность экспорта (память/CPU)

Экспорт покадровый, поэтому любые «на слайд/на кадр» аллокации быстро
превращаются в гигабайты. Что сделано:

- **Ограничение декодирования источников**: `RenderFrameConfiguration.effectiveSourceMaxPixelSize`
  (по умолчанию сторона холста x 1.4) применяется и к фото
  (`kCGImageSourceThumbnailMaxPixelSize`), и к кадрам видео
  (`AVAssetImageGenerator.maximumSize`). Полноразмерные 24-60 МП фото больше
  не декодируются целиком.
- **«База» фото-слайда считается один раз**: blur-фон + aspect-fit
  (`SlideImageCompositor.makeBase`) запекаются в растр размером холста и
  кэшируются (`photoBases`, LRU). Раньше Gaussian blur и отрисовка считались
  НА КАЖДОМ кадре.
- **Титр рисуется один раз на слайд** (`makeTitleImage`, LRU-кэш) вместо
  создания CGContext размером с холст на каждом кадре.
- **Исходники фото освобождаются** сразу после запекания базы; для слайда с
  готовой базой файл вообще не читается (иначе источник пересоздавался на
  каждом кадре).
- **LRU-ограничение кэшей** источников/баз (`maxCachedSources`,
  `maxCachedPhotoBases`) — память не растёт с числом слайдов.
- **Корректный backpressure**: кадр рендерится один раз, затем ожидание
  готовности `AVAssetWriterInput` (раньше кадр рендерился и выбрасывался),
  `CIContext.clearCaches()` каждые 15 кадров.

- **Последовательное декодирование видео** (`AVAssetReader`): раньше каждый кадр
  брался через `AVAssetImageGenerator` с нулевым допуском — это seek + точный
  декод на КАЖДЫЙ кадр (≈8 мс/кадр, 52% времени экспорта видео-проекта). Теперь
  кадры читаются потоково (`VideoFrameSource.sequentialFrame`), ридер при
  необходимости стартует с нужного времени (быстрый «seek»); произвольный доступ
  (перемотка) остаётся за `AVAssetImageGenerator`. Декод видео: 4.3 с -> 0.16 с.
- **Blur фона считается на уменьшенной копии** холста (1/4) — для видео-слайдов
  фон пересчитывается на каждом кадре.

Замеры (16 фото 24 МП + 2 видео, экспорт 1080p/24fps): пик памяти
1627 МБ -> 455 МБ, время 9.7 с -> 3.0 с. Профиль времени после правок:
растеризация кадра (CI -> CVPixelBuffer) ≈ 0.8 с, рендер/декод ≈ 1.7 с,
ожидание аппаратного кодировщика ≈ 0.2-0.9 с (video-проекты), аудио/mux ≈ 0.
Дальнейший резерв — предварительное «запекание» следующего слайда в фоне
(декод фото 24 МП ≈ 100 мс на слайд).
Регрессионные тесты — `testRendererCachesStayBounded`,
`testSequentialAndBackwardFrameRequests`.

### 4.7 Оценка размера файла

`SlideshowExporter.estimatedFileSize` = `целевой битрейт x длительность / 8`.
Кодировщику задаётся ОДИН average bitrate для H.264 и H.265, поэтому оценка не
различается по кодекам (ранее H.265 ошибочно умножался на 0.6 — расхождение с
фактом). Длительность берётся через `MediaDurationResolver` (учитывает ассеты
медиатеки Фото).

Так как слайдшоу из статичных фото сжимается ЛУЧШЕ целевого битрейта, в окне
экспорта применяется выученный коэффициент `AppSettings.exportBitrateRatio(for:)`:
после каждого экспорта сохраняется фактическое отношение «размер / оценка»
(экспоненциальное сглаживание), и следующая оценка сходится к реальности.

## 5. Миниатюры
`ThumbnailCache` (memory NSCache + диск `~/Library/Caches/Lumislide/Thumbnails/`).
Ключ = путь + дата изменения. Миниатюры декодируются **сразу в размере карточки**
(≤512 px), сетка обновляется полным `reloadData` с дебаунсом.

## 6. UI
- Сетка слайдов — `NSCollectionView` (drag&drop reorder) внутри
  `NSViewRepresentable`. Обработка кликов — в `ThumbnailItem` (`mouseDown`):
  `NSCollectionView.mouseDown` в этой связке не вызывается, события обрабатывает
  `NSCollectionViewItem`. Мультивыделение: Cmd+клик — отдельная карточка,
  Shift+клик — диапазон от якоря. Выделение сохраняется по id слайдов при
  `reloadData()`; Delete/Backspace удаляет выделенные (локальный монитор клавиш,
  не зависит от first responder). Размер карточек — 120…600 px.
- При запуске автоматически открывается последний проект
  (`AppSettings.lastProjectPath`), иначе самый свежий; выделение в списке
  проектов привязано к текущему проекту (подсвечивается вся строка).
- На карточке показывается титр слайда, метка принудительного перехода — на
  строке с номером слайда (раньше «уезжала» к следующему ряду).
- Двойной щелчок по карточке открывает окно **просмотра слайда**
  (`SlideViewerWindowView` + `SlideViewerModel`): кадр рендерится
  `TimelineFrameRenderer` в фоне; навигация ← → ↑ ↓ / Home / End, Esc закрывает.
  Клавиши перехватываются в `SlideViewerWindow.sendEvent` (SwiftUI-хост не
  выпускает стрелки по цепочке ответчиков); Delete/Backspace удаляет текущий
  слайд. Диалоги (длительность слайда, пользовательское разрешение) закрываются
  по Esc (кнопке «Отмена» назначается Esc-эквивалент).
- Вспомогательные окна (Просмотр/Экспорт/Свойства/Настройки/Справка) —
  **по одному экземпляру** (`AppWindowsController`): повторное открытие
  активирует окно или пересоздаёт контент для другого проекта.
  Окно настроек открывается своим `NSWindow` (а не SwiftUI-сценой `Settings`):
  при кастомном `@NSApplicationDelegateAdaptor` responder-chain действие
  `showSettingsWindow:` не доходит до обработчика SwiftUI.
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
- Встроенной библиотеки музыки нет (только пользовательские файлы-плейлист).
