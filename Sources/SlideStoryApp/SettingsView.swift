import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Окно настроек приложения (раздел 11 ТЗ).
///
/// Папка проектов, длительность показа фото по умолчанию, автосохранение,
/// язык интерфейса (русский/английский).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent(L10n.text(.projectsFolder)) {
                HStack {
                    Text(settings.projectsDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button(L10n.text(.chooseFolder)) {
                        settings.chooseProjectsDirectory()
                    }
                }
            }

            LabeledContent(L10n.text(.defaultPhotoDuration)) {
                HStack {
                    Slider(value: $settings.defaultPhotoDuration, in: 1...30, step: 0.5)
                        .frame(width: 180)
                    Text(String(format: "%.1f s", settings.defaultPhotoDuration))
                        .monospacedDigit()
                        .frame(width: 52)
                }
            }

            Toggle(L10n.text(.autosave), isOn: $settings.autosaveEnabled)

            Picker(L10n.text(.language), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 240)
        .padding()
    }
}
