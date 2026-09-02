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

    /// Завершён ли экспорт успешно (кнопка «Экспорт» → «Готово»).
    @State private var didFinishExport = false

    /// Длительность таймлайна (для оценки размера файла).
    @State private var timelineDuration: Double = 0
    /// Отформатированная оценка размера («≈ 128 МБ»), пусто — пока не посчитана.
    @State private var estimatedSizeText: String = ""

    private var presets: [AspectRatio.ResolutionPreset] {
        aspectRatio.presets
    }

    private var selectedSize: CGSize {
        presets.first(where: { $0.id == presetID })?.size ?? .init(width: 1920, height: 1080)
    }

    /// Заголовок главной кнопки окна экспорта.
    private var primaryButtonTitle: String {
        if isExporting { return L10n.text(.cancelExport) }
        if didFinishExport { return L10n.text(.done) }
        return "\(L10n.text(.export))…"
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
                .onChange(of: codec) { _, _ in updateEstimatedSize() }

                Picker(L10n.text(.aspectRatio), selection: $aspectRatio) {
                    ForEach(AspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }
                .onChange(of: aspectRatio) { _, newValue in
                    presetID = newValue.presets.contains(where: { $0.id == presetID })
                        ? presetID : newValue.presets[1].id
                    updateEstimatedSize()
                }

                Picker(L10n.text(.resolution), selection: $presetID) {
                    ForEach(presets, id: \.id) { preset in
                        Text("\(preset.id) (\(Int(preset.size.width))×\(Int(preset.size.height)))")
                            .tag(preset.id)
                    }
                }
                .onChange(of: presetID) { _, _ in updateEstimatedSize() }

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
                .onChange(of: quality) { _, _ in updateEstimatedSize() }

                // Оценка размера итогового файла.
                if !estimatedSizeText.isEmpty {
                    LabeledContent(L10n.text(.estimatedFileSize)) {
                        Text(estimatedSizeText)
                            .monospacedDigit()
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
                Button(isExporting ? L10n.text(.cancel) : L10n.text(.close)) {
                    if isExporting { cancelExport() } else { onClose() }
                }
                Button(primaryButtonTitle) {
                    if isExporting {
                        cancelExport()
                    } else if didFinishExport {
                        onClose()
                    } else {
                        startExport()
                    }
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

            // Длительность проекта (резолвинг видео-файлов может занять
            // время) — считаем в фоне, чтобы не блокировать окно.
            let project = self.project
            Task.detached(priority: .userInitiated) {
                let duration = SlideshowExporter.projectDuration(project)
                await MainActor.run {
                    self.timelineDuration = duration
                    self.updateEstimatedSize()
                }
            }
        }
        .onDisappear { exporter?.cancel() }
    }

    // MARK: - Оценка размера файла

    private func updateEstimatedSize() {
        guard timelineDuration > 0 else {
            estimatedSizeText = ""
            return
        }
        let bytes = SlideshowExporter.estimatedFileSize(
            duration: timelineDuration,
            codec: codec,
            resolution: selectedSize,
            quality: quality
        )
        estimatedSizeText = Self.formatBytes(bytes)
    }

    private static func formatBytes(_ bytes: Double) -> String {
        let mb = bytes / (1024 * 1024)
        if mb >= 1024 {
            return String(format: L10n.text(.approxGB), "\(Int(mb / 1024))")
        }
        return String(format: L10n.text(.approxMB), "\(Int(mb))")
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
        didFinishExport = false
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
                    didFinishExport = true
                    statusMessage = L10n.text(.exportFinished)
                    progress = 1
                    self.exporter = nil
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    didFinishExport = false
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

