import Foundation
import AVFoundation
import SlideStoryModel

/// Ошибки работы с аудио.
public enum AudioTrackMixerError: Error, LocalizedError, Sendable {
    case cannotOpenAudio(String)
    case invalidProject

    public var errorDescription: String? {
        switch self {
        case .cannotOpenAudio(let name):
            return "Cannot open audio file: \(name)."
        case .invalidProject:
            return "Invalid project configuration."
        }
    }
}

/// Микшер фоновой музыки под длительность итогового видео.
///
/// Правила:
/// - музыка звучит только на «фото-интервалах» (см. `MusicTimelinePlanner`);
/// - при включённом ducking музыка дополнительно звучит на видео-интервалах
///   с приглушённой громкостью;
/// - на границах интервалов — плавные переходы громкости (1 c);
/// - плейлист из нескольких треков проигрывается последовательно по кругу.
public enum AudioTrackMixer {

    /// Сегмент звучания музыки (на фото — полная громкость, на видео — приглушено).
    private struct MusicSegment {
        let interval: PhotoInterval
        let ducked: Bool
    }

    // MARK: - Полная аудио-дорожка проекта

    /// Результат построения аудио-дорожки проекта.
    public struct AudioMixResult {
        public let composition: AVMutableComposition
        public let audioMix: AVAudioMix?
    }

    /// Строит полную аудио-дорожку слайдшоу.
    /// - Parameters:
    ///   - project: проект (музыка, слайды).
    ///   - timeline: таймлайн проекта.
    ///   - musicURLs: URL файлов музыки (плейлист; пусто — музыки нет).
    public static func makeProjectAudioComposition(
        project: SlideshowProject,
        timeline: [SlideTimelineItem],
        musicURLs: [URL]
    ) throws -> AudioMixResult {
        let composition = AVMutableComposition()
        var allParameters: [AVMutableAudioMixInputParameters] = []
        var accessHolders: [SecurityScopedAccess] = []

        // 1. Собственные дорожки видео-слайдов.
        for item in timeline where item.kind == .video {
            let slide = project.slides[item.slideIndex]
            guard let resolved = try? MediaResolver.resolveWithAccess(slide) else { continue }
            if let holder = resolved.accessHolder {
                accessHolders.append(holder)
            }
            let asset = AVURLAsset(url: resolved.url)
            guard let sourceTrack = asset.tracks(withMediaType: .audio).first else { continue }
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let start = CMTime(seconds: item.startTime, preferredTimescale: 600)
            let slideDuration = CMTime(seconds: item.duration, preferredTimescale: 600)
            let sourceDuration = asset.duration
            let duration = min(slideDuration, sourceDuration)
            guard duration.seconds > 0 else { continue }

            do {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: start
                )
            } catch {
                continue
            }

            let params = AVMutableAudioMixInputParameters(track: compTrack)
            params.setVolume(1.0, at: .zero)
            allParameters.append(params)
        }

        // 2. Фоновая музыка (плейлист).
        let intervals = photoIntervals(project: project, timeline: timeline)
        if !musicURLs.isEmpty {
            var segments: [MusicSegment] = []
            if project.music.duckingEnabled {
                let total = TimelineBuilder.totalDuration(of: timeline)
                for interval in intervals {
                    segments.append(MusicSegment(interval: interval, ducked: false))
                }
                for gap in gapIntervals(photoIntervals: intervals, total: total) {
                    segments.append(MusicSegment(interval: gap, ducked: true))
                }
                segments.sort { $0.interval.start < $1.interval.start }
            } else {
                segments = intervals.map { MusicSegment(interval: $0, ducked: false) }
            }

            if !segments.isEmpty {
                try insertMusic(
                    musicURLs: musicURLs,
                    segments: segments,
                    settings: project.music,
                    into: composition,
                    parameters: &allParameters
                )
            }
        }

        let audioMix: AVAudioMix?
        if allParameters.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = allParameters
            audioMix = mix
        }

        return AudioMixResult(composition: composition, audioMix: audioMix)
    }

    /// Вычисляет фото-интервалы для проекта.
    public static func photoIntervals(project: SlideshowProject, timeline: [SlideTimelineItem]) -> [PhotoInterval] {
        MusicTimelinePlanner.photoIntervals(
            slideKinds: project.slides.map(\.kind),
            slideStartTimes: timeline.map(\.startTime),
            slideEndTimes: timeline.map(\.endTime),
            transitionDurations: timeline.map(\.transitionDuration)
        )
    }

    /// «Пробелы» между фото-интервалами (то есть видео-участки с учётом фейдов).
    private static func gapIntervals(photoIntervals: [PhotoInterval], total: Double) -> [PhotoInterval] {
        var gaps: [PhotoInterval] = []
        var cursor = 0.0
        for interval in photoIntervals {
            if interval.start > cursor + 0.01 {
                gaps.append(PhotoInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if total > cursor + 0.01 {
            gaps.append(PhotoInterval(start: cursor, end: total))
        }
        return gaps
    }

    // MARK: - Вставка музыки

    /// Вставляет плейлист музыки по сегментам (последовательно, по кругу)
    /// и применяет громкостные рампы (full/ducked + фейды 1 c).
    private static func insertMusic(
        musicURLs: [URL],
        segments: [MusicSegment],
        settings: MusicSettings,
        into composition: AVMutableComposition,
        parameters: inout [AVMutableAudioMixInputParameters]
    ) throws {
        struct Track { let asset: AVURLAsset; let track: AVAssetTrack; let duration: Double }
        var playlist: [Track] = []
        for url in musicURLs {
            let asset = AVURLAsset(url: url)
            guard let tr = asset.tracks(withMediaType: .audio).first else { continue }
            let d = asset.duration.seconds
            guard d.isFinite, d > 0 else { continue }
            playlist.append(Track(asset: asset, track: tr, duration: d))
        }
        guard !playlist.isEmpty else {
            throw AudioTrackMixerError.cannotOpenAudio(musicURLs.first?.lastPathComponent ?? "music")
        }

        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioTrackMixerError.cannotOpenAudio("music")
        }

        let params = AVMutableAudioMixInputParameters(track: compTrack)
        params.setVolume(Float(settings.volume), at: .zero)

        // Общий курсор по плейлисту: продолжается между сегментами без сброса.
        var trackIndex = 0
        var trackOffset = 0.0

        for segment in segments {
            var remaining = segment.interval.duration
            var insertAt = CMTime(seconds: segment.interval.start, preferredTimescale: 600)
            while remaining > 0.0001 {
                let track = playlist[trackIndex]
                let available = track.duration - trackOffset
                let chunk = min(remaining, available)
                guard chunk > 0 else {
                    trackIndex = (trackIndex + 1) % playlist.count
                    trackOffset = 0
                    continue
                }
                do {
                    try compTrack.insertTimeRange(
                        CMTimeRange(
                            start: CMTime(seconds: trackOffset, preferredTimescale: 600),
                            duration: CMTime(seconds: chunk, preferredTimescale: 600)
                        ),
                        of: track.track,
                        at: insertAt
                    )
                } catch {
                    throw AudioTrackMixerError.cannotOpenAudio("music")
                }
                insertAt = CMTimeAdd(insertAt, CMTime(seconds: chunk, preferredTimescale: 600))
                remaining -= chunk
                trackOffset += chunk
                if trackOffset >= track.duration - 0.001 {
                    trackIndex = (trackIndex + 1) % playlist.count
                    trackOffset = 0
                }
            }
        }

        applyLevelRamps(params: params, segments: segments, settings: settings)
        parameters.append(params)
    }

    /// Громкостные рампы: полная громкость на фото, приглушённая на видео,
    /// плавные переходы (1 c) между сегментами.
    private static func applyLevelRamps(
        params: AVMutableAudioMixInputParameters,
        segments: [MusicSegment],
        settings: MusicSettings
    ) {
        guard !segments.isEmpty else { return }
        let full = Float(settings.volume)
        let ducked = Float(settings.volume * (1 - settings.duckingLevel))
        let fade = MusicSettings.fadeDuration

        for (index, segment) in segments.enumerated() {
            let level = segment.ducked ? ducked : full
            let prevLevel: Float = index == 0 ? 0 : (segments[index - 1].ducked ? ducked : full)
            let nextLevel: Float = index == segments.count - 1 ? 0 : (segments[index + 1].ducked ? ducked : full)

            let start = CMTime(seconds: segment.interval.start, preferredTimescale: 600)
            let end = CMTime(seconds: segment.interval.end, preferredTimescale: 600)
            let half = segment.interval.duration / 2
            let fadeIn = CMTime(seconds: min(fade, half), preferredTimescale: 600)
            let fadeOut = CMTime(seconds: min(fade, half), preferredTimescale: 600)

            params.setVolumeRamp(
                fromStartVolume: prevLevel,
                toEndVolume: level,
                timeRange: CMTimeRange(start: start, duration: fadeIn)
            )
            let outStart = CMTimeSubtract(end, fadeOut)
            params.setVolumeRamp(
                fromStartVolume: level,
                toEndVolume: nextLevel,
                timeRange: CMTimeRange(start: outStart, duration: fadeOut)
            )
        }
    }

    /// Экспортирует аудио-композицию в AAC-файл (m4a) через AVAssetExportSession.
    public static func exportAudioMix(_ result: AudioMixResult, to outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let exportSession = AVAssetExportSession(
                asset: result.composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw AudioTrackMixerError.invalidProject
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            exportSession.audioMix = result.audioMix

            let semaphore = DispatchSemaphore(value: 0)
            exportSession.exportAsynchronously {
                semaphore.signal()
            }
            semaphore.wait()

            if exportSession.status != .completed {
                throw AudioTrackMixerError.invalidProject
            }
        }.value
    }
}
