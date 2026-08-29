import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import SlideStoryModel
import SlideStoryRenderer

/// Окно предпросмотра (раздел 9 ТЗ).
///
/// Проигрывает собранное слайдшоу — тот же рендер-пайплайн, что и при
/// экспорте, но в пониженном разрешении (живой рендер кадров).
/// Управление: play/pause, шкала прогресса (индикатор, без скраббинга).
struct PreviewWindowView: View {
    let project: SlideshowProject

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var currentImage: NSImage?
    @State private var duration: Double = 0
    @State private var errorMessage: String?
    @State private var volume: Double = 1.0
    /// Идёт ли перемотка слайдером (скраббинг).
    @State private var isScrubbing = false
    /// Воспроизводился ли ролик до начала перемотки (для автовозобновления).
    @State private var wasPlayingBeforeScrub = false

    private let renderer: PreviewRenderer

    init(project: SlideshowProject) {
        self.project = project
        self.renderer = PreviewRenderer(project: project)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Кадр.
            Group {
                if let currentImage {
                    Image(nsImage: currentImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                        Text(errorMessage)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView(L10n.text(.preparing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Прогресс (с перемоткой: drag обновляет кадр и аудио).
            Slider(value: $currentTime, in: 0...max(duration, 0.1)) { editing in
                if editing {
                    // Начало перемотки: запоминаем состояние и останавливаем
                    // воспроизведение, чтобы таймер не «воевал» со слайдером.
                    wasPlayingBeforeScrub = isPlaying
                    isPlaying = false
                    isScrubbing = true
                    renderer.pause()
                } else {
                    isScrubbing = false
                    // Фиксируем кадр и позицию аудио в конечной точке перемотки.
                    renderer.seek(to: currentTime)
                    if wasPlayingBeforeScrub {
                        isPlaying = true
                        renderer.play()
                    }
                }
            }
            .disabled(duration <= 0)
            .onChange(of: currentTime) { _, newValue in
                // Во время перемотки обновляем кадр и аудио в реальном времени.
                guard isScrubbing, !isPlaying else { return }
                renderer.seek(to: newValue)
            }

            HStack {
                Button(action: { togglePlay() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 20))

                Text(Self.formatTime(currentTime) + " / " + Self.formatTime(duration))
                    .font(.system(size: 12).monospacedDigit())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 100)
                }
            }
        }
        .padding(16)
        .onAppear(perform: startPlayback)
        .onDisappear {
            isPlaying = false
            renderer.stop()
        }
        .onChange(of: volume) { _, newValue in
            renderer.setVolume(newValue)
        }
    }

    private func togglePlay() {
        if isPlaying {
            isPlaying = false
            renderer.pause()
        } else {
            isPlaying = true
            renderer.play()
        }
    }

    private func startPlayback() {
        duration = renderer.timelineDuration()
        renderer.onFrame = { time, image in
            self.currentTime = time
            self.currentImage = image
        }
        renderer.onError = { message in
            self.errorMessage = message
        }
        isPlaying = true
        renderer.play()
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Живой рендер кадров для предпросмотра.
@MainActor
final class PreviewRenderer {
    let project: SlideshowProject
    private var timeline: [SlideTimelineItem] = []
    private var renderer: TimelineFrameRenderer?
    private let ciContext = CIContext()
    private var timer: Timer?
    private var startTime: Date?
    private var pausedTime: Double = 0
    private var isRunning = false

    /// Аудио-плеер полной дорожки проекта (музыка по фото-интервалам +
    /// собственные дорожки видео-слайдов). Композиция собирается асинхронно
    /// при инициализации; до готовности звук отсутствует.
    private var audioPlayer: AVPlayer?
    private var audioVolume: Double = 1.0
    private var isAudioReady = false

    var onFrame: ((Double, NSImage) -> Void)?
    var onError: ((String) -> Void)?

    init(project: SlideshowProject) {
        self.project = project
        let canvas = project.exportSettings.aspectRatio.canvasSize(height: 540)
        renderer = TimelineFrameRenderer(
            configuration: RenderFrameConfiguration(canvasSize: canvas, renderScale: 0.5)
        )
        // Видео-слайды должны длиться как исходное видео, а не как фото
        // (проблема 3): резолвим фактические длительности перед сборкой таймлайна.
        timeline = TimelineBuilder.buildTimeline(
            project: project,
            videoDurations: Self.resolveVideoDurations(project: project)
        )
        prepareAudio()
    }

    /// Возвращает фактические длительности видео-слайдов (секунды) по индексу.
    private static func resolveVideoDurations(project: SlideshowProject) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (index, slide) in project.slides.enumerated() where slide.kind == .video {
            guard let resolved = try? BookmarkResolver.resolve(slide.bookmarkData),
                  let source = try? VideoFrameSource(url: resolved.url, accessHolder: resolved.accessHolder) else { continue }
            result[index] = source.duration
        }
        return result
    }

    // MARK: - Аудио

    /// Собирает аудио-дорожку проекта и подготавливает AVPlayer.
    private func prepareAudio() {
        let hasAudio = project.music.source != nil
            || project.slides.contains { $0.kind == .video }
        guard hasAudio else { return }

        let project = self.project
        let timeline = self.timeline
        let musicURL = Self.resolveMusicURL(project: project)

        // Построение композиции — тяжёлая синхронная работа (AVURLAsset
        // читает треки лениво). Выполняем на фоновом потоке, чтобы не
        // блокировать главный поток на время построения. AVPlayer создаётся
        // на главном потоке (требование AVFoundation).
        Task.detached(priority: .userInitiated) {
            guard let result = try? AudioTrackMixer.makeProjectAudioComposition(
                project: project,
                timeline: timeline,
                musicURL: musicURL
            ), result.audioMix != nil else { return }

            let item = AVPlayerItem(asset: result.composition)
            item.audioMix = result.audioMix

            await MainActor.run {
                guard self.audioPlayer == nil else { return }
                let player = AVPlayer(playerItem: item)
                player.volume = Float(self.audioVolume)
                self.audioPlayer = player
                self.isAudioReady = true

                // Ключевой момент: звук готовится асинхронно и может стать
                // доступным уже ПОСЛЕ старта воспроизведения. Подхватываем его
                // в текущей позиции — иначе до паузы+play звука не будет.
                if self.isRunning {
                    self.syncAudio(to: self.currentPlaybackTime())
                    player.play()
                }
            }
        }
    }

    private static func resolveMusicURL(project: SlideshowProject) -> URL? {
        guard case .userFile(let ref) = project.music.source,
              let resolved = try? BookmarkResolver.resolve(ref.bookmarkData) else { return nil }
        return resolved.url
    }

    /// Текущая позиция воспроизведения (для синхронизации аудио).
    private func currentPlaybackTime() -> Double {
        if isRunning, let startTime {
            return Date().timeIntervalSince(startTime)
        }
        return pausedTime
    }

    /// Синхронизирует аудио-плеер с текущим временем проигрывания.
    private func syncAudio(to time: Double) {
        guard isAudioReady, let audioPlayer else { return }
        audioPlayer.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Управление

    /// Перемотка: рендерит кадр в произвольной позиции и синхронизирует аудио.
    func seek(to time: Double) {
        let clamped = min(max(time, 0), timelineDuration())
        pausedTime = clamped
        syncAudio(to: clamped)
        onFrame?(clamped, frame(at: clamped) ?? NSImage())
    }

    func timelineDuration() -> Double {
        TimelineBuilder.totalDuration(of: timeline)
    }

    func play() {
        guard !isRunning, !timeline.isEmpty else { return }
        isRunning = true
        startTime = Date().addingTimeInterval(-pausedTime)
        syncAudio(to: pausedTime)
        audioPlayer?.play()
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        audioPlayer?.pause()
        if let startTime {
            pausedTime = Date().timeIntervalSince(startTime)
        }
    }

    func stop() {
        pause()
        pausedTime = 0
        syncAudio(to: 0)
        audioPlayer?.pause()
    }

    func setVolume(_ volume: Double) {
        audioVolume = min(max(volume, 0), 1)
        audioPlayer?.volume = Float(audioVolume)
    }

    private func tick() {
        guard isRunning, let startTime else { return }
        let time = Date().timeIntervalSince(startTime)
        let total = timelineDuration()
        if time >= total {
            pause()
            pausedTime = 0
            onFrame?(total, frame(at: max(total - 0.001, 0)) ?? NSImage())
            return
        }
        onFrame?(time, frame(at: time) ?? NSImage())
    }

    private func frame(at time: Double) -> NSImage? {
        guard let renderer else { return nil }
        do {
            let ciImage = try renderer.makeFrame(at: time, timeline: timeline, project: project)
            let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
            guard let cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            onError?(error.localizedDescription)
            return nil
        }
    }
}


