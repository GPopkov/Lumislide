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
/// Правила (ТЗ v1.1):
/// - музыка звучит только на «фото-интервалах» (см. `MusicTimelinePlanner`);
/// - на границах интервалов — плавный fade in/out (2 c);
/// - трек зацикливается/обрезается под суммарную длительность интервалов;
/// - если проект состоит только из видео — музыка не звучит.
public enum AudioTrackMixer {

    /// Утилита: применяет плавные fade in/out на каждом интервале.
    private static func applyFades(
        to params: AVMutableAudioMixInputParameters,
        photoIntervals: [PhotoInterval],
        fadeDuration: Double
    ) {
        for interval in photoIntervals {
            let fadeIn = min(fadeDuration, interval.duration / 2)
            let fadeOut = min(fadeDuration, interval.duration / 2)
            let start = CMTime(seconds: interval.start, preferredTimescale: 600)
            let fadeInEnd = CMTimeAdd(start, CMTime(seconds: fadeIn, preferredTimescale: 600))
            let fadeOutStartTime = CMTimeAdd(start, CMTime(seconds: max(interval.duration - fadeOut, 0), preferredTimescale: 600))

            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: CMTimeRange(start: start, end: fadeInEnd)
            )
            params.setVolumeRamp(
                fromStartVolume: 1,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: fadeOutStartTime, end: CMTimeAdd(start, CMTime(seconds: interval.duration, preferredTimescale: 600)))
            )
        }
    }

    // MARK: - Полная аудио-дорожка проекта

    /// Результат построения аудио-дорожки проекта.
    public struct AudioMixResult {
        public let composition: AVMutableComposition
        public let audioMix: AVAudioMix?
    }

    /// Строит полную аудио-дорожку слайдшоу:
    ///
    /// - для каждого видео-слайда вставляется его собственная аудио-дорожка
    ///   (в интервале слайда на таймлайне);
    /// - фоновая музыка звучит только на фото-интервалах (затухание 2 c
    ///   перед видео, появление после), зацикливаясь при необходимости.
    ///
    /// - Parameters:
    ///   - project: проект (музыка, слайды).
    ///   - timeline: таймлайн проекта.
    ///   - musicURL: URL файла музыки (nil — музыки нет).
    /// - Returns: композиция с аудио-дорожками и audioMix (громкость/фейды).
    public static func makeProjectAudioComposition(
        project: SlideshowProject,
        timeline: [SlideTimelineItem],
        musicURL: URL?
    ) throws -> AudioMixResult {
        let composition = AVMutableComposition()
        var allParameters: [AVMutableAudioMixInputParameters] = []
        // Удерживаем security-scoped доступ на всё время построения:
        // AVURLAsset читает треки лениво.
        var accessHolders: [SecurityScopedAccess] = []

        // 1. Собственные дорожки видео-слайдов.
        for item in timeline where item.kind == .video {
            let slide = project.slides[item.slideIndex]
            guard let resolved = try? BookmarkResolver.resolve(slide.bookmarkData) else { continue }
            accessHolders.append(resolved.accessHolder)
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

        // 2. Фоновая музыка на фото-интервалах.
        let intervals = photoIntervals(project: project, timeline: timeline)
        if let musicURL, !intervals.isEmpty {
            try insertMusic(
                musicURL: musicURL,
                intervals: intervals,
                volume: project.music.volume,
                into: composition,
                parameters: &allParameters
            )
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

    /// Вставляет музыку по фото-интервалам (с зацикливанием и фейдами).
    private static func insertMusic(
        musicURL: URL,
        intervals: [PhotoInterval],
        volume: Double,
        into composition: AVMutableComposition,
        parameters: inout [AVMutableAudioMixInputParameters]
    ) throws {
        let musicAsset = AVURLAsset(url: musicURL)
        guard let musicTrack = musicAsset.tracks(withMediaType: .audio).first else {
            throw AudioTrackMixerError.cannotOpenAudio(musicURL.lastPathComponent)
        }
        let musicDuration = musicAsset.duration.seconds
        guard musicDuration.isFinite, musicDuration > 0 else {
            throw AudioTrackMixerError.cannotOpenAudio(musicURL.lastPathComponent)
        }

        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioTrackMixerError.cannotOpenAudio(musicURL.lastPathComponent)
        }

        let params = AVMutableAudioMixInputParameters(track: compTrack)
        params.setVolume(Float(volume), at: .zero)

        for interval in intervals {
            let start = CMTime(seconds: interval.start, preferredTimescale: 600)

            // Зацикливание кусками.
            var remaining = interval.duration
            var insertAt = start
            while remaining > 0 {
                let chunk = min(remaining, musicDuration)
                let chunkTime = CMTime(seconds: chunk, preferredTimescale: 600)
                do {
                    try compTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: chunkTime),
                        of: musicTrack,
                        at: insertAt
                    )
                } catch {
                    throw AudioTrackMixerError.cannotOpenAudio(musicURL.lastPathComponent)
                }
                insertAt = CMTimeAdd(insertAt, chunkTime)
                remaining -= chunk
            }

            // Фейды на границах интервала.
            applyFades(to: params, photoIntervals: [interval], fadeDuration: MusicSettings.fadeDuration)
        }

        parameters.append(params)
    }


    /// Экспортирует аудио-композицию в AAC-файл (m4a) через AVAssetExportSession.
    /// - Parameters:
    ///   - result: результат `makeProjectAudioComposition`.
    ///   - outputURL: URL итогового аудиофайла.
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

