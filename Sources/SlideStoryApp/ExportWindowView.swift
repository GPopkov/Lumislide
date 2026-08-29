import SwiftUI
import AppKit
import SlideStoryModel
import SlideStoryRenderer

/// Окно экспорта (раздел 10 ТЗ).
///
/// Параметры: кодек (H.264/H.265), разрешение, частота кадров, качество,
/// соотношение сторон (наследуется из проекта, можно переопределить).
/// Прогресс-бар с процентом и оценкой оставшегося времени, отмена.
/// Итоговый файл сохраняется через NSSavePanel в `.mp4`.
struct ExportWindowView: View {
    let project: SlideshowProject

    /// Закрытие окна. Окно открывается через NSHostingController+NSWindow,
    /// где SwiftUI `@Environment(\.dismiss)` не работает.
    var onClose: () -> Void

    @State private var codec: VideoCodec = .h264
    @State private var aspectRatio: AspectRatio = .landscape16x9
    @State private var presetID: String = "1080p"
    @State private var frameRate: FrameRate = .fps30
    @State private var quality: VideoQuality = .high

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var timeRemaining: Double = 0
    @State private var statusMessage: String = L10n.text(.ready)
    @State private var exportError: String?

    @State private var exporter: SlideshowExporter?

    private var presets: [AspectRatio.ResolutionPreset] {
        aspectRatio.presets
    }

    private var selectedSize: CGSize {
        presets.first(where: { $0.id == presetID })?.size ?? .init(width: 1920, height: 1080)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(.export))
                .font(.headline)

            Form {
                Picker(L10n.text(.codec), selection: $codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("H.265 (HEVC)").tag(VideoCodec.h265)
                }

                Picker(L10n.text(.aspectRatio), selection: $aspectRatio) {
                    ForEach(AspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
                .onChange(of: aspectRatio) { _, newValue in
                    presetID = newValue.presets.contains(where: { $0.id == presetID })
                        ? presetID : newValue.presets[1].id
                }

                Picker(L10n.text(.resolution), selection: $presetID) {
                    ForEach(presets, id: \.id) { preset in
                        Text("\(preset.id) (\(Int(preset.size.width))×\(Int(preset.size.height)))")
                            .tag(preset.id)
                    }
                }

                Picker(L10n.text(.frameRate), selection: $frameRate) {
                    Text("24 fps").tag(FrameRate.fps24)
                    Text("25 fps").tag(FrameRate.fps25)
                    Text("30 fps").tag(FrameRate.fps30)
                }

                Picker(L10n.text(.quality), selection: $quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { q in
                        Text(q.displayName).tag(q)
                    }
                }
            }
            .disabled(isExporting)

            Divider()

            // Прогресс.
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                HStack {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isExporting, timeRemaining > 0 {
                        Text("~ \(Int(timeRemaining)) \(L10n.text(.timeLeft))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.text(.cancel)) {
                    if isExporting { cancelExport() } else { onClose() }
                }
                Button(isExporting ? L10n.text(.cancelExport) : "\(L10n.text(.export))…") {
                    if isExporting { cancelExport() } else { startExport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(project.slides.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 430)
        .onAppear {
            aspectRatio = project.exportSettings.aspectRatio
            codec = project.exportSettings.codec
            frameRate = project.exportSettings.frameRate
            quality = project.exportSettings.quality
            presetID = aspectRatio.presets[1].id
        }
        .onDisappear { exporter?.cancel() }
    }

    // MARK: - Экспорт

    private func startExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let request = ExportRequest(
            codec: codec,
            resolution: selectedSize,
            frameRate: frameRate,
            quality: quality,
            transitionDuration: project.transitionDuration,
            photoDuration: project.defaultPhotoDuration,
            outputURL: url
        )

        let exporter = SlideshowExporter(project: project, request: request)
        self.exporter = exporter
        isExporting = true
        statusMessage = L10n.text(.exporting)
        progress = 0

        exporter.onProgress = { value in
            Task { @MainActor in
                self.progress = value.fractionCompleted
                self.timeRemaining = value.estimatedTimeRemaining
            }
        }

        // Экспорт — синхронный и долгий; запускаем на фоновом потоке,
        // чтобы не блокировать main actor (иначе UI зависнет на весь экспорт).
        let exporterRef = exporter
        Task.detached(priority: .userInitiated) {
            do {
                try exporterRef.export()
                await MainActor.run {
                    isExporting = false
                    statusMessage = L10n.text(.exportFinished)
                    progress = 1
                    self.exporter = nil
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    if (error as? SlideshowExportError) == .cancelled {
                        statusMessage = L10n.text(.exportCancelled)
                    } else {
                        exportError = error.localizedDescription
                        statusMessage = L10n.text(.exportFailed)
                    }
                    self.exporter = nil
                }
            }
        }
    }

    private func cancelExport() {
        exporter?.cancel()
        statusMessage = L10n.text(.exportCancelled)
    }
}

