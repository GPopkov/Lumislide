# Lumislide

**Lumislide** — нативное приложение для macOS, которое собирает слайд-шоу из ваших
фото и видео и сохраняет его в MP4. Добавляйте файлы, расставляйте карточки в сетке —
приложение само склеит ролик: переходы, эффект Кена Бёрнса, титры, фоновая музыка.

> Требования: **macOS 15 (Sequoia) или новее**, компьютер **на Apple Silicon (M1+)**.

---

## English

### What is Lumislide?

A native macOS app that turns your photos and videos into an MP4 slideshow.

- Your files are **never imported or copied**: Lumislide keeps only references
  (sandboxed bookmarks) to the originals and reads them on the fly.
- No timeline to learn: the **card order in the grid equals the order in the video**.
  Drag cards to reorder.
- Everything is automatic by default — Lumislide picks transitions, applies the
  Ken Burns effect and (if it finds faces) focuses the motion on the faces.

### Main features

- **Media**: JPEG, HEIC, PNG photos; MOV/MP4 videos. Add files with “Add media”
  or pick from your **Photos library**.
- **Auto intro & outro**: every new project begins with a title slide (project name)
  and ends with a black “The End” slide.
- **11 transitions**, applied automatically and deterministically; you can force a
  specific transition per slide (right-click a card).
- **Ken Burns** slow zoom/pan on photos with **face-aware focus**.
- **Titles** on photos: text, size, color, position.
- **Background music** on photo intervals (2 s fade around videos); video slides
  keep their own audio.
- **Aspect ratios**: 16:9, 4:3, 9:16, 1:1. Media is fitted (no cropping); empty
  space is filled with a blurred copy of the same image.
- **Live preview** window — the same pipeline as export, at lower resolution.
- **Export** to MP4 (H.264 or H.265) with configurable resolution / frame rate /
  quality, progress, cancellation and an estimated output size.
- **Localization**: English and Russian (the main menu and Help follow the language).

### Requirements

- macOS 15.0 or newer (Sequoia)
- Apple Silicon (M1 or newer)

### Download & install

1. Download the latest release from the **Releases** page:
   [github.com/GPopkov/Lumislide/releases](https://github.com/GPopkov/Lumislide/releases)
   — file `Lumislide-<version>.zip`.
2. Unzip and move **Lumislide.app** to your `Applications` folder.
3. First launch: the app is distributed without App Store notarization, so macOS
   may block it. Right-click the app → **Open** → **Open** (once). Afterwards it
   launches normally.

> Or build it yourself from source — see
> [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) (Russian, with a short English summary).

### Quick start

1. **Create a project** — click **“+ Create”** in the left sidebar (a new project
   already contains the intro and outro slides).
2. **Add media** — toolbar **“Add media”** (choose files) or **“From Photos library”**.
   The files appear between the intro and the outro.
3. **Arrange** — drag cards to set the order; right-click a card to change its
   transition, add a title or disable Ken Burns for it.
4. **Project settings** — toolbar “Properties”: rename, photo/transition duration,
   Ken Burns on/off, aspect ratio, background music.
5. **Preview** — the play button runs the slideshow live.
6. **Export** — “Export”: pick resolution/frame rate/quality, then wait for the MP4.

### Where are my projects?

Projects are saved as `.slideshow` files in **`~/Lumislide Projects`**
(inside the app’s sandbox container on macOS). Each project stores only references
to your media — the files themselves stay where they are.

### FAQ

- **“Lumislide can’t be opened because it is from an unidentified developer”**
  → right-click the app → Open → Open. The app is ad-hoc signed and sandboxed;
  you can remove the quarantine flag with
  `xattr -d com.apple.quarantine /Applications/Lumislide.app`.
- **Photos are shown sideways / the app needs access to a file?** → the app asks
  for access when you add files; if a file was moved, right-click its card →
  “Relink file”.
- **Can I use music from Apple Music / streaming?** Only local audio files are
  supported (MP3, WAV, AIFF, AAC, FLAC).
- **The video looks blurry around photos with a different aspect ratio** — that is
  intentional: media is fitted and the bars are filled with a blurred copy.

### Documentation

- [Technical documentation (RU)](docs/TECHNICAL.md) — architecture, project file
  format, render pipeline, Ken Burns & coordinates, transitions, audio, testing.
- [Development guide (RU)](docs/DEVELOPMENT.md) — building and testing from source.

---

<!--RU-->

## На русском

### Что такое Lumislide?

Нативное приложение для macOS, которое превращает ваши фото и видео в MP4-слайд-шоу.

- Файлы **не импортируются и не копируются**: приложение хранит только ссылки
  (security-scoped bookmarks) и читает оригиналы на лету.
- Никакого таймлайна: **порядок карточек в сетке = порядок в ролике**. Перетаскивайте
  карточки, чтобы изменить последовательность.
- Всё автоматически по умолчанию — приложение само выбирает переходы, применяет
  эффект Кена Бёрнса и (если находит лица) **наводит движение на лица**.

### Возможности

- **Медиа**: фото JPEG, HEIC, PNG; видео MOV/MP4. Добавление файлов кнопкой
  «Добавить медиа» или выбор из **медиатеки Фото**.
- **Авто-Intro и Outro**: каждый новый проект начинается титульным слайдом
  (название проекта) и заканчивается чёрным слайдом «Конец».
- **11 переходов** — подбираются автоматически и детерминированно; для конкретного
  слайда можно задать свой (ПКМ по карточке).
- **Кен Бёрнс** — медленный зум/панорама с **фокусом на лица**.
- **Титры** на фото: текст, размер, цвет, положение.
- **Фоновая музыка** на фото-интервалах (fade 2 c вокруг видео); на видео-слайдах
  остаётся собственная звуковая дорожка.
- **Пропорции кадра**: 16:9, 4:3, 9:16, 1:1. Медиа вписывается без обрезки;
  пустые поля заполняются размытой копией того же изображения.
- **Окно предпросмотра** — тот же конвейер, что и при экспорте, в пониженном
  разрешении.
- **Экспорт** в MP4 (H.264 или H.265): разрешение / частота кадров / качество,
  прогресс, отмена и оценка размера файла.
- **Локализация**: русский и английский (меню и справка следуют языку).

### Системные требования

- macOS 15.0 или новее (Sequoia)
- Apple Silicon (M1 и новее)

### Скачать и установить

1. Скачайте последний релиз со страницы **Releases**:
   [github.com/GPopkov/Lumislide/releases](https://github.com/GPopkov/Lumislide/releases)
   — файл `Lumislide-<версия>.zip`.
2. Распакуйте и переместите **Lumislide.app** в папку `Программы`.
3. Первый запуск: приложение распространяется без нотаризации App Store, поэтому
   macOS может его заблокировать. Нажмите на приложение **правой кнопкой** →
   **«Открыть»** → **«Открыть»** (один раз). Дальше оно запускается как обычно.

> Либо соберите из исходников — см.
> [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

### Быстрый старт

1. **Создайте проект** — кнопка **«+ Создать»** в левой колонке (в новом проекте
   уже есть Intro и Outro-слайды).
2. **Добавьте медиа** — в тулбаре **«Добавить медиа»** (выбор файлов) или
   **«Из медиатеки Фото»**. Файлы встанут между Intro и Outro.
3. **Расставьте порядок** — перетаскивайте карточки; ПКМ по карточке: сменить
   переход, добавить титр или отключить Кена Бёрнса.
4. **Свойства проекта** — тулбар «Свойства»: название, длительность фото/переходов,
   Кен Бёрнс вкл/выкл, пропорции, фоновая музыка.
5. **Предпросмотр** — кнопка «Просмотр» запускает слайд-шоу вживую.
6. **Экспорт** — «Экспорт»: выберите разрешение/частоту кадров/качество и дождитесь MP4.

### Где хранятся проекты?

Проекты сохраняются как файлы `.slideshow` в папке **`~/Lumislide Projects`**
(в песочнице приложения). В проекте — только ссылки на медиа; сами файлы остаются
на своих местах.

### Частые вопросы

- **«Lumislide нельзя открыть, так как оно от неизвестного разработчика»**
  → правая кнопка по приложению → «Открыть» → «Открыть». Приложение подписано
  ad-hoc и работает в песочнице; снять пометку карантина можно командой
  `xattr -d com.apple.quarantine /Applications/Lumislide.app`.
- **Фото повёрнуто / приложение не видит файл?** → доступ запрашивается при
  добавлении файлов; если файл переместили — ПКМ по карточке → «Переподключить файл».
- **Можно ли музыку из Apple Music/стриминга?** Только локальные аудиофайлы
  (MP3, WAV, AIFF, AAC, FLAC).
- **Почему по краям видео размытие?** Это задумано: медиа вписывается целиком,
  а пустые поля заполняются размытой копией.

### Документация

- [Техническая документация](docs/TECHNICAL.md) — архитектура, формат файла проекта,
  конвейер рендера, Ken Burns и координаты, переходы, аудио, тесты.
- [Руководство разработчика](docs/DEVELOPMENT.md) — сборка и тесты из исходников.
