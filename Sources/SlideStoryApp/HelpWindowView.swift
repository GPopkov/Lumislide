import SwiftUI
import AppKit

/// Окно справки (Help → «Справка Lumislide»).
/// Содержимое — двуязычное, отображается на текущем языке интерфейса.
struct HelpWindowView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(L10n.text(.lumislideHelp), systemImage: "questionmark.circle")
                    .font(.title2.bold())

                ForEach(Array(L10n.helpSections().enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.headline)
                        Text(section.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
