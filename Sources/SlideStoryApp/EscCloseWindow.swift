import AppKit

/// Окно, закрывающееся по Esc (`cancelOperation`).
///
/// Используется для всех программных окон приложения (предпросмотр, экспорт,
/// свойства проекта) и для sheet-окон (редактор титра). Если окно — лист,
/// Esc завершает лист (`endSheet`), иначе закрывает окно (`performClose`).
final class EscCloseWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if isSheet, let parent = sheetParent {
            parent.endSheet(self)
        } else {
            performClose(sender)
        }
    }
}
