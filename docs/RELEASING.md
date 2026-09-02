# Релизный процесс (GitHub Releases)

> **English summary.** Releases distribute the prebuilt, sandboxed **Lumislide.app**
> (Apple Silicon, macOS 15+) as `Lumislide-<version>.zip` attached to a GitHub
> Release. Build + sign locally (needs a development identity), zip, then publish via
> `gh` or the GitHub API using a token with `repo` scope. Full text in Russian below.

---

1. **Подготовка кода**: все изменения на `main`, тесты зелёные
   (`swift test`, 55+).

2. **Версия**: принят формат `vX.Y.Z`. Тег и название релиза — `v1.0.0`.

3. **Сборка и подпись** (на машине с Apple Development identity):

   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   ./Scripts/build_app.sh direct
   ```

4. **Проверка**: запустить `dist/Lumislide.app`, открыть проект, предпросмотр,
   экспорт одного короткого ролика.

5. **Упаковка**:

   ```bash
   cd dist && ditto -c -k --keepParent Lumislide.app Lumislide-1.0.0.zip
   ```

6. **Публикация** на GitHub (один из способов):
   - через `gh`:
     ```bash
     gh release create v1.0.0 dist/Lumislide-1.0.0.zip \
         --title "Lumislide 1.0.0" --notes "…"
     ```
   - через API (классический токен со scope `repo`):
     ```bash
     curl -X POST -H "Authorization: token $GH_TOKEN" \
       https://api.github.com/repos/GPopkov/Lumislide/releases \
       -d '{"tag_name":"v1.0.0","name":"Lumislide 1.0.0"}'
     # затем upload-asset по url из ответа
     ```

7. **Проверка релиза**: на странице Releases лежит zip; README ссылается на
   `releases/latest`.

> Примечание: приложение подписано ad-hoc/development и не нотаризовано — при первом
> запуске пользователь открывает его через ПКМ → «Открыть» (см. README, FAQ).
