# Lumislide

**Lumislide** is a native macOS app for building slideshows from your photos and videos.
Add media files, arrange them in the grid, and the app assembles a video: automatic
transitions, Ken Burns effect, background music, titles — then export to **H.264 / H.265**.

> Requirements: **macOS 15.0+ (Sequoia)**, **Apple Silicon only** (no Intel support).

---

## English

### Overview

Lumislide has **no built-in media library**. Your photos and videos are never imported
or copied — the project stores only security-scoped bookmarks (references) to the original
files, which are read on the fly during preview and export. Everything works inside the
macOS sandbox.

### Features

- **Drag & drop grid editor** — reorder slides by dragging cards (`NSCollectionView`).
- **12 transitions** between slides:
  - Core Image: dissolve, slide left, slide right, wipe, push, iris open, iris close;
  - Custom Metal kernels: rotate inward, rotate outward, door, grid, color fade.
  - Transitions are applied **automatically and deterministically** (project seed), or
    forced per slide via right-click.
- **Ken Burns effect** on photos — slow zoom/pan with a **face-aware focus point**
  (Vision `VNDetectFaceRectanglesRequest`, bounding box only, fully on-device).
- **Titles** — text overlay per photo (font size, color, position: top/center/bottom).
- **Background music** — attach your own audio file (by reference, not imported).
  Music plays only during photo slides (2 s fades around videos); video slides keep
  their **own audio track**.
- **Aspect ratios** 16:9, 9:16, 1:1. No cropping: media is fitted and the empty space
  is filled with a blurred, stretched copy of the same image.
- **Live preview window** — same render pipeline as export, at reduced resolution.
- **Export** to MP4 (H.264 or H.265), configurable resolution / frame rate / quality,
  with progress and cancellation.
- **Localization**: English / Russian.

### Requirements

- macOS 15.0 or later
- Apple Silicon (M1 or newer)
- Xcode (for building and running the tests) — Command Line Tools alone are not enough
  for `swift test` (XCTest)

### Build & run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if CLT is active
swift build
swift test
swift run Lumislide
```

### Project structure

Three independent Swift modules (Swift Package Manager):

| Module | Path | Purpose |
|---|---|---|
| `SlideStoryModel` | `Sources/SlideStoryModel` | Codable project model, `.slideshow` file store, security-scoped bookmark resolver — no UI / rendering dependencies |
| `SlideStoryRenderer` | `Sources/SlideStoryRenderer` | Render pipeline: Ken Burns, transitions (CI + Metal), video frames, exporter, audio mixer |
| `SlideStoryApp` | `Sources/SlideStoryApp` | UI layer: SwiftUI + AppKit (thumbnail grid via `NSCollectionView`), windows, view models |

### Architecture highlights

1. **No media library** — files are referenced via security-scoped bookmarks and read
   only during preview/export (works in sandbox and outside).
2. **Slide order = grid order**; no separate timeline UI.
3. **Deterministic randomness** — automatic transitions are seeded by the project
   (`transitionSeed`, 64-bit, stored as a string in JSON); re-exporting an unchanged
   project yields the identical result. Manual per-slide override via right-click.
4. **No cropping** — `.fit` + blurred background fill for mismatched aspect ratios.
5. **Ken Burns considers faces** — Vision bounding boxes only, no identity detection.
6. **Music on photo intervals only** (2 s fade around video slides), looped/trimmed to
   the slideshow duration; video slides keep their own audio.

### Release build (.app)

```bash
# Mac App Store (sandbox signing)
./Scripts/build_app.sh mas

# Direct distribution (sandbox + hardened runtime)
./Scripts/build_app.sh direct

# Notarization (direct channel)
APPLE_ID="you@example.com" APPLE_PASSWORD="xxxx-xxxx-xxxx" \
    ./Scripts/notarize.sh dist/Lumislide.app
```

The result is `dist/Lumislide.app`. Requires an Apple Development identity
(Xcode → Settings → Accounts).

### Supported formats

| Kind | Formats |
|---|---|
| Photos | JPEG, HEIC, PNG |
| Videos | MOV, MP4 (H.264/H.265) |
| Export | MP4 container, H.264 or H.265 |
| Project file | `.slideshow` (JSON) |
| Music | MP3, WAV, AIFF, AAC, FLAC |

### Testing

`swift test` runs the full suite: model tests (timeline, transitions, Ken Burns,
bookmarks, music intervals), renderer tests (export, video frames, face detection),
and app tests (localization, settings, import).

### Known limitations (v1)

- Video frames are extracted with `AVAssetImageGenerator` with per-frame seeking —
  a bottleneck on long/high-fps video slides (planned replacement: `AVAssetReader`).
- The blurred background fill for video slides is recomputed every frame
  (photos: computed once and cached).
- Face detection may run on the fly during export if not cached in the project file.
- Watch-folder mode is modeled in the data layer (`watchFolderBookmark`) but has no UI yet.
- The built-in music library is not shipped in v1 (only user-provided music);
  bundled tracks require redistribution-compatible licensing.

---

## На русском

### Обзор

**Lumislide** — нативное macOS-приложение для сборки слайдшоу из ваших фото и видео.
Добавьте медиафайлы, расположите их в сетке — приложение само соберёт видео:
автоматические переходы, эффект Кена Бёрнса, фоновая музыка, титры — и экспортирует
результат в **H.264 / H.265**.

> Требования: **macOS 15.0+ (Sequoia)**, **только Apple Silicon** (Intel не поддерживается).

### Возможности

- **Редактор-сетка с drag & drop** — порядок слайдов меняется перетаскиванием карточек
  (`NSCollectionView`).
- **12 переходов** между слайдами:
  - Core Image: растворение, скольжение влево/вправо, вытеснение, сдвиг,
    открытие/закрытие круга;
  - кастомные Metal-кернелы: вращение внутрь, вращение наружу, дверь, сетка, цветной fade.
  - Переходы назначаются **автоматически и детерминированно** (seed проекта) либо
    принудительно для конкретного слайда через ПКМ.
- **Эффект Кена Бёрнса** на фото — медленный зум/панорама с **учётом лиц**
  (Vision `VNDetectFaceRectanglesRequest`, только bounding box, полностью on-device).
- **Титры** — текстовая накладка на фото (размер шрифта, цвет, позиция: сверху/по центру/снизу).
- **Фоновая музыка** — подключение собственного аудиофайла по ссылке (без импорта).
  Музыка звучит только на фото-слайдах (fade 2 c вокруг видео); на видео-слайдах
  звучит **собственная звуковая дорожка** видео.
- **Соотношения сторон** 16:9, 9:16, 1:1. Обрезка не применяется: медиа вписывается
  целиком, пустое пространство заполняется размытой растянутой копией того же кадра.
- **Окно предпросмотра** — тот же рендер-пайплайн, что и при экспорте, в пониженном
  разрешении (живой рендер кадров, play/pause, перемотка, громкость).
- **Экспорт** в MP4 (H.264 или H.265), настраиваемые разрешение / частота кадров /
  качество, прогресс и отмена.
- **Локализация**: русский / английский.

### Требования

- macOS 15.0 или новее
- Apple Silicon (M1 и новее)
- Xcode (для сборки и тестов) — Command Line Tools недостаточно для `swift test` (XCTest)


### Сборка и запуск

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # если активны CLT
swift build
swift test
swift run Lumislide
```

### Структура проекта

Три независимых Swift-модуля (Swift Package Manager):

| Модуль | Путь | Назначение |
|---|---|---|
| `SlideStoryModel` | `Sources/SlideStoryModel` | Codable-модель проекта, файл `.slideshow`, резолвер security-scoped bookmarks — без зависимостей от UI и рендеринга |
| `SlideStoryRenderer` | `Sources/SlideStoryRenderer` | Рендер-пайплайн: Ken Burns, переходы (CI + Metal), видео-кадры, экспортёр, аудио-микшер |
| `SlideStoryApp` | `Sources/SlideStoryApp` | UI-слой: SwiftUI + AppKit (сетка миниатюр через `NSCollectionView`), окна, view-model'и |


### Ключевые архитектурные решения

1. **Нет медиатеки** — фото/видео не импортируются, хранятся только security-scoped
   bookmarks; файлы читаются в момент предпросмотра/экспорта (работает и в sandbox, и вне его).
2. **Порядок слайдов = порядок карточек в сетке**; отдельного таймлайна в UI нет.
3. **Детерминированная случайность** — автоматические переходы задаются seed проекта
   (`transitionSeed`, 64-бит, строкой в JSON); повторный экспорт без изменений даёт
   идентичный результат. Ручной override — через ПКМ.
4. **Обрезка не применяется** — `.fit` + размытая заливка фона при несовпадении пропорций.
5. **Ken Burns учитывает лица** — Vision, только bounding box, без идентификации личности.
6. **Музыка только на фото-интервалах** (fade 2 c вокруг видео), зацикливается/обрезается
   под длительность; на видео-слайдах — собственная дорожка видео.


### Релизная сборка (.app)

```bash
# Mac App Store (sandbox-подпись)
./Scripts/build_app.sh mas

# Прямое распространение (sandbox + hardened runtime)
./Scripts/build_app.sh direct

# Notarization (direct-канал)
APPLE_ID="you@example.com" APPLE_PASSWORD="xxxx-xxxx-xxxx" \
    ./Scripts/notarize.sh dist/Lumislide.app
```

Результат — `dist/Lumislide.app`. Требуется Apple Development identity
(Xcode → Settings → Accounts).

### Форматы

| Тип | Форматы |
|---|---|
| Фото | JPEG, HEIC, PNG |
| Видео | MOV, MP4 (H.264/H.265) |
| Экспорт | MP4-контейнер, H.264 или H.265 |
| Файл проекта | `.slideshow` (JSON) |
| Музыка | MP3, WAV, AIFF, AAC, FLAC |


### Тесты

`swift test` запускает полный набор: тесты модели (таймлайн, переходы, Ken Burns,
bookmarks, интервалы музыки), рендерера (экспорт, видео-кадры, детекция лиц)
и приложения (локализация, настройки, импорт).

### Известные ограничения v1

- Кадры видео извлекаются через `AVAssetImageGenerator` с повторным seek — узкое место
  на длинных видео-слайдах с высоким fps (план: замена на `AVAssetReader`).
- Размытая заливка для видео пересчитывается на каждый кадр (для фото — один раз и кэш).
- Детекция лиц может выполняться «на лету» при экспорте, если не закэширована в проекте.
- Watch-folder заложен в модели данных (`watchFolderBookmark`), UI в v1 не реализован.
- Встроенная библиотека музыкальных треков в v1 не поставляется (только пользовательская
  музыка); встроенные треки требуют лицензии на распространение.

