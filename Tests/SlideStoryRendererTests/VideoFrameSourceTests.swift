import XCTest
import Foundation
import CoreGraphics
import CoreImage
import AVFoundation
@testable import SlideStoryRenderer
@testable import SlideStoryModel

/// Тесты источника кадров видео.
///
/// Регрессия: у видео с аудио-дорожкой длиннее видеодорожки (запись экрана,
/// mux с более длинным аудио) контейнерная длительность больше реального
/// диапазона кадров. Запрос кадра в «хвосте» падал с
/// «cannot open video asset frame at 29,9s».
final class VideoFrameSourceTests: XCTestCase {

    /// Регрессия: «Cannot open video asset: frame at 0.0s.» — у файлов, где
    /// первый кадр дорожки смещён от нуля (edit list / склейки), запрос кадра
    /// в 0 с нулевым допуском не находит кадр и падал.
    func testVideoWithNonZeroTrackStartReturnsFirstFrame() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("lumi-vfs-offset-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try TestMediaFactory.makeBaseVideo(url: url, duration: 2, startOffset: 0.3)

        let source = try VideoFrameSource(url: url)
        XCTAssertEqual(source.duration, 2.0, accuracy: 0.4)

        // Не должно бросать (раньше: cannotOpenAsset("frame at 0.0s")).
        let firstFrame = try source.frame(atTime: 0)
        XCTAssertGreaterThan(firstFrame.extent.width, 0)

        let lastFrame = try source.frame(atTime: source.duration)
        XCTAssertGreaterThan(lastFrame.extent.width, 0)
    }

    /// Видео с ведущим пустым участком (дорожка стартует не в нуле, как после
    /// склейки/edit list). Кадр в 0 раньше не находился и рендер падал.
    func testVideoWithLeadingEmptyEditReturnsFirstFrame() throws {
        let dir = FileManager.default.temporaryDirectory
        let baseURL = dir.appendingPathComponent("lumi-edit-base-\(UUID().uuidString).mp4")
        let outURL = dir.appendingPathComponent("lumi-edit-out-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        try TestMediaFactory.makeBaseVideo(url: baseURL, duration: 2)
        let asset = AVURLAsset(url: baseURL)
        guard let src = asset.tracks(withMediaType: .video).first else {
            throw XCTSkip("no video track")
        }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw XCTSkip("cannot add track") }
        // Смещаем дорожку на 0.3 c — в начале пустой участок.
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: src,
            at: CMTime(seconds: 0.3, preferredTimescale: 600)
        )

        guard let export = AVAssetExportSession(
            asset: comp,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw XCTSkip("no export session") }
        export.outputURL = outURL
        export.outputFileType = .mov
        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        guard export.status == .completed else {
            throw XCTSkip("export failed: \(export.error?.localizedDescription ?? "unknown")")
        }

        let source = try VideoFrameSource(url: outURL)
        // Регрессия: падало с «frame at 0.0s», если дорожка стартует не в нуле.
        let frame = try source.frame(atTime: 0)
        XCTAssertGreaterThan(frame.extent.width, 0)
    }

    /// Видео с аудио длиннее видео (контейнер 7 c, кадры до 5 c):
    /// - `duration` должна равняться длительности видеодорожки, а не контейнера;
    /// - кадры в пределах дорожки извлекаются;
    /// - запрос «в хвосте» не падает (возвращается последний кадр).
    func testVideoWithLongerAudioUsesVideoTrackDuration() throws {
        let dir = FileManager.default.temporaryDirectory
        let baseURL = dir.appendingPathComponent("lumi-vfs-base-\(UUID().uuidString).mp4")
        let wavURL = dir.appendingPathComponent("lumi-vfs-\(UUID().uuidString).wav")
        let muxURL = dir.appendingPathComponent("lumi-vfs-mux-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: muxURL)
        }

        try TestMediaFactory.makeBaseVideo(url: baseURL, duration: 5)   // видеодорожка 5 c
        try TestMediaFactory.writeWAV(url: wavURL, duration: 7)          // аудио 7 c
        try TestMediaFactory.mux(videoURL: baseURL, audioURL: wavURL, out: muxURL)

        let source = try VideoFrameSource(url: muxURL)

        // Длительность = реальная видеодорожка (5 c), а не контейнер (7 c).
        XCTAssertEqual(source.duration, 5.0, accuracy: 0.3)

        // Кадр внутри дорожки — извлекается.
        let nearEnd = try source.frame(atTime: 4.9)
        XCTAssertGreaterThan(nearEnd.extent.width, 0)

        // Запрос за пределами дорожки (в «хвосте») не падает с ошибкой —
        // возвращается последний доступный кадр (регрессия «frame at 29,9s»).
        let inTail = try source.frame(atTime: 6.5)
        XCTAssertGreaterThan(inTail.extent.width, 0)
    }
}
