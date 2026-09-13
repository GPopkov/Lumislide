import SwiftUI
import AppKit
import SlideStoryModel

/// Модальное окно «Свойства проекта».
///
/// Название, длительность переходов, длительность фото, Ken Burns, пропорции,
/// фоновая музыка (плейлист из нескольких треков + ducking) и громкость.
struct ProjectPropertiesView: View {
    let project: SlideshowProject
    @ObservedObject var store: ProjectsStore

    /// Закрытие окна (окно открыто через NSHostingController+NSWindow).
    var onClose: () -> Void

    @State private var name: String = ""
    @State private var transitionDuration: Double = 1.0
    @State private var photoDuration: Double = 5.0
    @State private var kenBurnsEnabled = true
    @State private var aspectRatio: AspectRatio = .landscape16x9
    @State private var musicRefs: [MediaAudioReference] = []
    @State private var musicVolume: Double = 0.7
    @State private var duckingEnabled = true
    @State private var duckingLevel: Double = 0.5

    private var musicSummary: String {
        musicRefs.isEmpty ? "None" : musicRefs.map(\.displayName).joined(separator: ", ")
    }

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

                if musicRefs.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(musicRefs, id: \.id) { ref in
                        HStack {
                            Text(ref.displayName)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                musicRefs.removeAll { $0.id == ref.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    Button(L10n.text(.chooseAudioFile)) { chooseMusic() }
                    Button(L10n.text(.removeMusic)) { musicRefs.removeAll() }
                        .disabled(musicRefs.isEmpty)
                }

                LabeledContent(L10n.text(.volume)) {
                    Slider(value: $musicVolume, in: 0...1, step: 0.05)
                        .frame(width: 180)
                }

                Toggle(L10n.text(.ducking), isOn: $duckingEnabled)
                if duckingEnabled {
                    LabeledContent(L10n.text(.duckingLevel)) {
                        Slider(value: $duckingLevel, in: 0...1, step: 0.05)
                            .frame(width: 180)
                    }
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
        .frame(width: 480, height: 540)
        .onAppear(perform: load)
    }

    private func load() {
        name = project.name
        transitionDuration = project.transitionDuration
        photoDuration = project.defaultPhotoDuration
        kenBurnsEnabled = project.isKenBurnsEnabled
        aspectRatio = project.exportSettings.aspectRatio
        musicRefs = project.music.source?.trackReferences ?? []
        musicVolume = project.music.volume
        duckingEnabled = project.music.duckingEnabled
        duckingLevel = project.music.duckingLevel
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .audio, .mpeg4Audio]
        panel.message = L10n.text(.chooseAudioFile)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        // Создание bookmark'ов в фоне (не блокируем UI).
        Task.detached(priority: .userInitiated) {
            var refs: [MediaAudioReference] = []
            for url in urls {
                guard let bookmark = try? BookmarkResolver.createBookmark(for: url) else { continue }
                BookmarkResolver.registerSessionURL(url, forBookmark: bookmark)
                refs.append(MediaAudioReference(bookmarkData: bookmark, displayName: url.lastPathComponent))
            }
            await MainActor.run {
                self.musicRefs.append(contentsOf: refs)
            }
        }
    }

    private func removeMusic() {
        musicRefs.removeAll()
    }

    private func save() {
        store.mutate { project in
            project.name = name
            project.defaultPhotoDuration = photoDuration
            project.transitionDuration = transitionDuration
            project.isKenBurnsEnabled = kenBurnsEnabled
            project.exportSettings.aspectRatio = aspectRatio
            project.music.volume = musicVolume
            project.music.duckingEnabled = duckingEnabled
            project.music.duckingLevel = duckingLevel
            project.music.source = musicRefs.isEmpty ? nil : .userFiles(musicRefs)
        }
    }
}

import UniformTypeIdentifiers
