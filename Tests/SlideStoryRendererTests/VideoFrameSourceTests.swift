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
