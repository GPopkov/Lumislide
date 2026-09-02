# Руководство разработчика (сборка, тесты, релиз)

> **English summary.** Build with Xcode (not only Command Line Tools — XCTest is
> required): `swift build`, `swift test`, `swift run Lumislide`. Release `.app`
> bundles are produced by `./Scripts/build_app.sh mas|direct` (needs an Apple
> Development signing identity); `direct` adds sandbox + hardened runtime and can be
> notarized with `./Scripts/notarize.sh`. Publishing a release is described in
> `RELEASING.md`. Full text below in Russian.

---

## Требования

- macOS 15+, Apple Silicon;
- **Xcode** (для `swift test` нужен XCTest — одних Command Line Tools мало);
- для релизной подписи — Apple Development identity
  (Xcode → Settings → Accounts) и, для нотаризации, Apple ID + app-specific password.

## Повседневная разработка

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # если активны CLT

swift build        # собрать исполняемый бинарь
swift test         # весь набор тестов (модель, рендерер, приложение)
swift run Lumislide
```

Кодовая база — Swift Package Manager, три модуля:

- `SlideStoryModel` — модель/файл проекта, bookmarks (без UI и рендера);
- `SlideStoryRenderer` — рендер, переходы, аудио, экспорт, детекция лиц;
- `SlideStoryApp` — UI (исполняемый таргет Lumislide).

## Релизный .app бандл

```bash
./Scripts/build_app.sh mas      # подпись для Mac App Store (sandbox)
./Scripts/build_app.sh direct   # прямая дистрибуция (sandbox + hardened runtime)
```

Скрипт: собирает `swift build -c release`, собирает `dist/Lumislide.app`,
копирует ресурсные бандлы SPM (Metal-шейдеры) и подписывает с entitlements
(`Supporting/Entitlements/MAS.entitlements` или `Direct.entitlements`).

> ВАЖНО: в `TransitionBlender` Metal-шейдеры дублируются встроенной строкой
> (`metalSource`) — при изменении `Resources/Transitions.metal` правьте и её.

Нотаризация (direct-канал):

```bash
APPLE_ID="you@example.com" APPLE_PASSWORD="xxxx-xxxx-xxxx" \
    ./Scripts/notarize.sh dist/Lumislide.app
```

## Полезные проверки

- Тесты ориентации Metal-переходов — `MetalTransitionOrientationTests`.
- Детекция лиц и координаты — тесты Ken Burns в `RendererLogicTests`
  (фокус на лицо, маппинг изображение→холст, границы кадра).
- Локализация: каждый ключ L10n обязан иметь RU и EN переводы (AppTests).
