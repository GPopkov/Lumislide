import SwiftUI
import AppKit
import SlideStoryModel

/// Редактор титра для слайда (открывается из ПКМ «Добавить титр…»).
struct TitleEditorView: View {
    let slideID: UUID
    @ObservedObject var store: ProjectsStore

    /// Закрытие sheet-окна. Открывается через NSWindow.beginSheet, где
    /// SwiftUI `@Environment(\.dismiss)` не работает.
    var onClose: () -> Void

    @State private var text: String = ""
    @State private var fontSize: Double = 48
    @State private var color: Color = .white
    @State private var position: TitlePosition = .center

    private var existingTitle: TitleOverlay? {
        store.currentProject?.slides.first(where: { $0.id == slideID })?.titleOverlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(.title))
                .font(.headline)

            TextField(L10n.text(.text), text: $text)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(L10n.text(.fontSize))
                Slider(value: $fontSize, in: 12...120, step: 1)
                Text("\(Int(fontSize))")
                    .monospacedDigit()
                    .frame(width: 40)
            }

            HStack {
                Text(L10n.text(.color))
                ColorPicker("", selection: $color, supportsOpacity: false)
                Spacer()
            }
            Picker(L10n.text(.position), selection: $position) {
                Text(L10n.text(.top)).tag(TitlePosition.top)
                Text(L10n.text(.center)).tag(TitlePosition.center)
                Text(L10n.text(.bottom)).tag(TitlePosition.bottom)
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button(L10n.text(.cancel)) { onClose() }
                Button(L10n.text(.save)) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let title = existingTitle {
                text = title.text
                fontSize = title.fontSize
                color = Color(red: title.colorRGBA.x, green: title.colorRGBA.y, blue: title.colorRGBA.z)
                position = title.position
            }
        }
    }

    private func save() {
        guard !text.isEmpty else {
            // Пустой текст — удаляем титр.
            store.updateSlide(id: slideID) { $0.titleOverlay = nil }
            onClose()
            return
        }
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let overlay = TitleOverlay(
            text: text,
            fontSize: fontSize,
            colorRGBA: SIMD4<Double>(
                Double(nsColor.redComponent),
                Double(nsColor.greenComponent),
                Double(nsColor.blueComponent),
                1
            ),
            position: position
        )
        store.updateSlide(id: slideID) { $0.titleOverlay = overlay }
        onClose()
    }


}
