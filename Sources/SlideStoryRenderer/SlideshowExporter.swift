import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import SlideStoryModel

/// Ошибки экспорта.
public enum SlideshowExportError: Error, LocalizedError, Equatable, Sendable {
    case cannotCreateWriter(String)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddAudioTrack(String)
    case writingFailed(String)
    case cancelled
    case missingFile(String)
    case emptyTimeline

    public var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let path):
            return "Cannot create video writer: \(path)."
        case .cannotAddVideoInput:
            return "Cannot add video input to the writer."
        case .cannotAddAudioInput:
            return "Cannot add audio input to the writer."
        case .cannotAddAudioTrack(let name):
            return "Cannot add audio track: \(name)."
        case .writingFailed(let message):
            return "Writing failed: \(message)."
        case .cancelled:
            return "Export cancelled."
        case .missingFile(let name):
            return "File not available: \(name)."
        case .emptyTimeline:
            return "The project has no slides."
        }
    }
}

/// Ход экспорта.
public struct ExportProgress: Sendable {
    public var fractionCompleted: Double
    public var frameIndex: Int
    public var totalFrames: Int
    /// Оценка оставшегося времени в секундах.
    public var estimatedTimeRemaining: Double
}

/// Конфигурация экспорта (параметры, переопределяемые в окне экспорта).
public struct ExportRequest: Sendable {
    public var codec: VideoCodec
    public var resolution: CGSize
    public var frameRate: FrameRate
    public var quality: VideoQuality
    /// Длительность перехода (секунды).
    public var transitionDuration: Double
    /// Длительность фото (секунды).
    public var photoDuration: Double
    /// URL итогового файла.
    public var outputURL: URL

    public init(
        codec: VideoCodec,
        resolution: CGSize,
        frameRate: FrameRate,
        quality: VideoQuality,
        transitionDuration: Double,
        photoDuration: Double,
        outputURL: URL
    ) {
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.transitionDuration = transitionDuration
        self.photoDuration = photoDuration
        self.outputURL = outputURL
    }
}

/// Драйвер `AVAssetWriter` для экспорта слайдшоу в MP4 (H.264/H.265).
///
/// Покадрово вызывает `TimelineFrameRenderer`, пишет видео-дорожку,
/// отдаёт прогресс. Экспорт можно отменить.
public final class SlideshowExporter: @unchecked Sendable {
    private let project: SlideshowProject
    private let request: ExportRequest
    private let renderer: TimelineFrameRenderer
    private let ciContext: CIContext
    private let lock = NSLock()
    private var isCancelled = false

    /// Callback прогресса; вызывается на каждой итерации.
    public var onProgress: (@Sendable (ExportProgress) -> Void)?

    /// Инициализация экспортёра.
    /// - Parameters:
    ///   - project: проект.
    ///   - request: параметры экспорта.
    public init(project: SlideshowProject, request: ExportRequest) {
        self.project = project
        self.request = request
        self.renderer = TimelineFrameRenderer(
            configuration: RenderFrameConfiguration(canvasSize: request.resolution, renderScale: 1.0)
        )
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Отменяет экспорт (следующий кадр не будет записан).
    public func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    /// Синхронный экспорт.
    /// - Throws: `SlideshowExportError`.
    public func export() throws {
        try performExport().get()
    }

    // MARK: - Экспорт

    private func performExport() -> Result<Void, Error> {
        do {
            try removeExistingFile()
            try performWrite()
            return .success(())
        } catch {
            if isCancelled {
                return .failure(SlideshowExportError.cancelled)
            }
            return .failure(error)
        }
    }

    private func removeExistingFile() throws {
        if FileManager.default.fileExists(atPath: request.outputURL.path) {
            try? FileManager.default.removeItem(at: request.outputURL)
        }
    }

    private func performWrite() throws {
        // Проверка доступности всех файлов.
        try validateProject()

        let timeline = try makeTimeline()
        let totalFrames = Int((timelineDuration(timeline) * request.frameRate.fps).rounded(.up))

        // Видео-часть пишется во временный файл; аудио и финальный mux
        // выполняются после. Если аудио нет — temp-файл становится итогом.
        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-video-\(UUID().uuidString).mp4")

        do {
            try writeVideoTrack(to: tempVideoURL, timeline: timeline, totalFrames: totalFrames)

            // Удерживаем держатель security-scoped доступа к музыке на всё
            // время построения аудио-композиции (иначе доступ закроется
            // сразу и AVURLAsset не сможет прочитать файл в sandbox).
            let music = resolveMusicURL()
            let musicHolder = music?.accessHolder
            let audioResult = try AudioTrackMixer.makeProjectAudioComposition(
                project: project,
                timeline: timeline,
                musicURL: music?.url
            )

            if audioResult.audioMix != nil {
                // Есть аудио (музыка и/или дорожки видео) — пересобираем через mux.
                let tempAudioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lumi-audio-\(UUID().uuidString).m4a")
                try awaitWrite {
                    try await AudioTrackMixer.exportAudioMix(audioResult, to: tempAudioURL)
                }
                try muxVideo(at: tempVideoURL, audioAt: tempAudioURL, to: request.outputURL)
                try? FileManager.default.removeItem(at: tempAudioURL)
            } else {
                // Аудио нет — просто перемещаем видео.
                try FileManager.default.moveItem(at: tempVideoURL, to: request.outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempVideoURL)
            throw error
        }
    }

    /// Асинхронная операция с ожиданием (для exportAudioMix).
    private func awaitWrite(_ operation: @escaping () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrown: Error?
        Task {
            do {
                try await operation()
            } catch {
                thrown = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown { throw thrown }
    }


    /// Пишет видео-дорожку (без аудио) во временный файл.
    private func writeVideoTrack(to tempURL: URL, timeline: [SlideTimelineItem], totalFrames: Int) throws {
        let writer = try makeWriter(outputURL: tempURL)
        let videoInput = try makeVideoInput()
        guard writer.canAdd(videoInput) else {
            throw SlideshowExportError.cannotAddVideoInput
        }
        writer.add(videoInput)

        // Адаптер для записи CVPixelBuffer в видео-вход. Пул буферов берём
        // у адаптера (sourcePixelBufferAttributes) — он совместим с ожиданиями
        // AVAssetWriter (в т.ч. IOSurface для аппаратного кодирования).
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: request.resolution.width,
                kCVPixelBufferHeightKey as String: request.resolution.height,
            ]
        )

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameIndex = 0
        var loopError: Error?
        let startTime = Date()

        // Проходим по кадрам.
        while frameIndex < totalFrames {
            if isCancelled {
                writer.cancelWriting()
                throw SlideshowExportError.cancelled
            }

            // КРИТИЧНО: без autoreleasepool каждую итерацию накапливаются
            // autoreleased-объекты рендера (CGImage из AVAssetImageGenerator,
            // промежуточные CIImage/CIContext-текстуры) — память растёт ~8 МБ
            // на кадр 1080p и экспорт падает с OOM на длинных/видео-проектах.
            autoreleasepool {
                do {
                    let time = Double(frameIndex) / request.frameRate.fps
                    let frame = try renderFrame(at: time, timeline: timeline)

                    // Из CIImage → CVPixelBuffer (из пула адаптера).
                    var pixelBuffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                    }
                    guard let buffer = pixelBuffer else {
                        throw SlideshowExportError.writingFailed("cannot create pixel buffer")
                    }
                    ciContext.render(frame, to: buffer)

                    let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(request.frameRate.rawValue))
                    guard videoInput.isReadyForMoreMediaData else {
                        // Backpressure: ждём (кадр будет отрендерен заново).
                        usleep(1000)
                        return
                    }
                    adaptor.append(buffer, withPresentationTime: presentationTime)
                    frameIndex += 1
                    let elapsed = Date().timeIntervalSince(startTime)
                    let fraction = Double(frameIndex) / Double(max(totalFrames, 1))
                    let eta = fraction > 0 ? elapsed / fraction * (1 - fraction) : 0
                    onProgress?(ExportProgress(
                        fractionCompleted: fraction,
                        frameIndex: frameIndex,
                        totalFrames: totalFrames,
                        estimatedTimeRemaining: eta
                    ))
                } catch {
                    loopError = error
                }
            }

            if let loopError {
                throw loopError
            }
        }

        videoInput.markAsFinished()

        // Дожидаемся завершения записи.
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status != .completed {
            throw SlideshowExportError.writingFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Собирает видео+аудио в итоговый MP4 через AVAssetExportSession (mux).
    private func muxVideo(at videoURL: URL, audioAt audioURL: URL, to outputURL: URL) throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        if let videoTrack = videoAsset.tracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoAsset.duration),
                of: videoTrack,
                at: .zero
            )
        }
        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioAsset.duration),
                of: audioTrack,
                at: .zero
            )
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw SlideshowExportError.writingFailed("cannot create mux session")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        guard exportSession.status == .completed else {
            throw SlideshowExportError.writingFailed(
                exportSession.error?.localizedDescription ?? "mux failed"
            )
        }
    }

    /// Возвращает музыку проекта, если выбран пользовательский трек.
    /// Держатель security-scoped доступа должен удерживаться вызывающим.
    private func resolveMusicURL() -> ResolvedMediaFile? {
        guard case .userFile(let ref) = project.music.source else { return nil }
        return try? BookmarkResolver.resolve(ref.bookmarkData)
    }

    // MARK: - Валидация

    private func validateProject() throws {
        guard !project.slides.isEmpty else {
            throw SlideshowExportError.emptyTimeline
        }
        for slide in project.slides {
            if !MediaResolver.isAvailable(slide) {
                throw SlideshowExportError.missingFile(slide.displayName)
            }
        }
    }

    // MARK: - Таймлайн

    private func makeTimeline() throws -> [SlideTimelineItem] {
        let durations = try resolveVideoDurations()
        return TimelineBuilder.buildTimeline(
            project: project,
            videoDurations: durations
        )
    }

    private func resolveVideoDurations() throws -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (index, slide) in project.slides.enumerated() where slide.kind == .video {
            let resolved = try MediaResolver.resolveWithAccess(slide)
            // Держатель security-scoped доступа передаём источнику, чтобы файл
            // оставался доступным на всё время жизни источника (в sandbox
            // доступ закрывается сразу после резолвинга без держателя).
            let source = try VideoFrameSource(url: resolved.url, accessHolder: resolved.accessHolder)
            result[index] = source.duration
        }
        return result
    }

    private func timelineDuration(_ timeline: [SlideTimelineItem]) -> Double {
        TimelineBuilder.totalDuration(of: timeline)
    }

    private func renderFrame(at time: Double, timeline: [SlideTimelineItem]) throws -> CIImage {
        try renderer.makeFrame(at: time, timeline: timeline, project: project)
    }

    // MARK: - Writer

    private func makeWriter(outputURL: URL) throws -> AVAssetWriter {
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw SlideshowExportError.cannotCreateWriter(outputURL.path)
        }
        return writer
    }

    private func makeVideoInput() throws -> AVAssetWriterInput {
        let codec: AVVideoCodecType = request.codec == .h264 ? .h264 : .hevc
        let bitrate = request.quality.bitrateMultiplier * baseBitrate(for: request.resolution)

        let settings: [String: Any] = [
            AVVideoCodecKey: codec.rawValue,
            AVVideoWidthKey: request.resolution.width,
            AVVideoHeightKey: request.resolution.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: request.frameRate.rawValue,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func baseBitrate(for size: CGSize) -> Double {
        let megapixels = size.width * size.height / 1_000_000
        return megapixels * 2_000_000
    }

    // MARK: - Оценка размера итогового файла

    /// Общая длительность таймлайна проекта (с учётом фактических
    /// длительностей видео-слайдов). Используется для оценки размера файла.
    /// - Parameter project: проект.
    public static func projectDuration(_ project: SlideshowProject) -> Double {
        var videoDurations: [Int: Double] = [:]
        for (index, slide) in project.slides.enumerated() where slide.kind == .video {
            if let resolved = try? BookmarkResolver.resolve(slide.bookmarkData),
               let source = try? VideoFrameSource(url: resolved.url, accessHolder: resolved.accessHolder) {
                videoDurations[index] = source.duration
            }
        }
        let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: videoDurations)
        return TimelineBuilder.totalDuration(of: timeline)
    }

    /// Оценочный размер итогового видео (байт) для заданных параметров
    /// экспорта без реального рендера.
    ///
    /// Формула: `битрейт × длительность / 8`, где битрейт берётся тем же
    /// способом, что и при реальном экспорте (`baseBitrate × quality`).
    /// H.265 учитывается коэффициентом ~0.6 (эффективнее H.264).
    ///
    /// - Parameters:
    ///   - duration: длительность таймлайна в секундах.
    ///   - codec: кодек экспорта.
    ///   - resolution: разрешение холста.
    ///   - quality: качество (целевой битрейт).
    public static func estimatedFileSize(
        duration: Double,
        codec: VideoCodec,
        resolution: CGSize,
        quality: VideoQuality
    ) -> Double {
        guard duration > 0 else { return 0 }
        let megapixels = resolution.width * resolution.height / 1_000_000
        let bitrate = quality.bitrateMultiplier * (megapixels * 2_000_000)
        let codecFactor: Double = codec == .h265 ? 0.6 : 1.0
        return bitrate * duration / 8 * codecFactor
    }
}

