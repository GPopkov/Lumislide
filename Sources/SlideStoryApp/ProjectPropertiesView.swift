import SwiftUI
import AppKit
import SlideStoryModel

/// Модальное окно «Свойства проекта» (раздел 5 ТЗ).
///
/// Название, длительность переходов, длительность фото, Ken Burns вкл/выкл,
/// базовое соотношение сторон, фоновая музыка (пользовательский файл по
/// ссылке) и громкость.
struct ProjectPropertiesView: View {
    let project: SlideshowProject
    @ObservedObject var store: ProjectsStore

    /// Закрытие окна. Окно открывается через NSHostingController+NSWindow,
    /// где SwiftUI `@Environment(\.dismiss)` не работает.
    var onClose: () -> Void

    @State private var name: String = ""
    @State private var transitionDuration: Double = 1.0
    @State private var photoDuration: Double = 5.0
    @State private var kenBurnsEnabled = true
    @State private var aspectRatio: AspectRatio = .landscape16x9
    @State private var musicName: String = "None"
    @State private var musicVolume: Double = 0.7

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(.projectProperties))
                .font(.headline)

            Form {
                TextField(L10n.text(.name), text: $name)

                LabeledContent(L10n.text(.photoDuration)) {
                    HStack {
                        Slider(value: $photoDuration, in: 1...30, step: 0.5)
                        Text(String(format: "%.1f s", photoDuration))
                            .monospacedDigit()
                            .frame(width: 52)
                    }
                }

                LabeledContent(L10n.text(.transitionDuration)) {
                    HStack {
                        Slider(value: $transitionDuration, in: 0.1...5, step: 0.1)
                        Text(String(format: "%.1f s", transitionDuration))
                            .monospacedDigit()
                            .frame(width: 52)
                    }
                }

                Toggle(L10n.text(.kenBurnsEffect), isOn: $kenBurnsEnabled)

                Picker(L10n.text(.aspectRatio), selection: $aspectRatio) {
                    ForEach(AspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text(.backgroundMusic))
                    .font(.headline)
                Text(musicName)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text(.chooseAudioFile)) { chooseMusic() }
                    Button(L10n.text(.removeMusic)) { removeMusic() }
                        .disabled(musicName == "None")
                }
                LabeledContent(L10n.text(.volume)) {
                    Slider(value: $musicVolume, in: 0...1, step: 0.05)
                        .frame(width: 180)
                }
            }

            Spacer()

            HStack {
                Text(L10n.text(.musicPlaysOnlyDuringPhotos))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text(.close)) { save(); onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 460)
        .onAppear(perform: load)
    }

    private func load() {
        name = project.name
        transitionDuration = project.transitionDuration
        photoDuration = project.defaultPhotoDuration
        kenBurnsEnabled = project.isKenBurnsEnabled
        aspectRatio = project.exportSettings.aspectRatio
        musicVolume = project.music.volume

        switch project.music.source {
        case .userFile(let ref):
            musicName = ref.displayName
        case .builtIn(let id):
            musicName = "Built-in: \(id)"
        case .none:
            musicName = "None"
        }
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .audio, .mpeg4Audio]
        panel.message = L10n.text(.chooseAudioFile)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { return }
        let ref = MediaAudioReference(bookmarkData: bookmark, displayName: url.lastPathComponent)
        musicName = ref.displayName

        store.mutate { project in
            project.music.source = .userFile(ref)
        }
    }

    private func removeMusic() {
        musicName = "None"
        store.mutate { project in
            project.music.source = nil
        }
    }

    private func save() {
        store.mutate { project in
            project.name = name
            project.defaultPhotoDuration = photoDuration
            project.transitionDuration = transitionDuration
            project.isKenBurnsEnabled = kenBurnsEnabled
            project.exportSettings.aspectRatio = aspectRatio
            project.music.volume = musicVolume
        }
    }
}

import UniformTypeIdentifiers
