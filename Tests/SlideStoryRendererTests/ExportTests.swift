import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import SlideStoryRenderer
@testable import SlideStoryModel

/// Тесты экспорта: корректность выходного файла и устойчивость длинных циклов
/// записи (регрессия: утечка памяти в цикле кадров приводила к крашу экспорта
/// на ~30 секундах).
final class ExportTests: XCTestCase {

    /// Создаёт синтетическое фото PNG во временной папке.
    private func makeTestPhoto(_ name: String, width: Int = 320, height: Int = 200, hue: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-export-\(UUID().uuidString)-\(name).png")
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: hue, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw NSError(domain: "test", code: 1) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw NSError(domain: "test", code: 2) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "test", code: 3) }
        return url
    }

    private func makeProject(photoCount: Int, photoDuration: Double = 2, transitionDuration: Double = 0.5) throws -> SlideshowProject {
        var project = SlideshowProject(name: "Export Test")
        project.defaultPhotoDuration = photoDuration
        project.transitionDuration = transitionDuration
        project.isKenBurnsEnabled = false
        project.slides = try (0..<photoCount).map { index in
            let url = try makeTestPhoto("\(index)", hue: CGFloat(index) / 7)
            let bookmark = try BookmarkResolver.createBookmark(for: url)
            return MediaReference(kind: .photo, bookmarkData: bookmark, displayName: url.lastPathComponent)
        }
        return project
    }

    private func runExport(project: SlideshowProject, resolution: CGSize = CGSize(width: 320, height: 180)) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-export-test-\(UUID().uuidString).mp4")
        let request = ExportRequest(
            codec: .h264,
            resolution: resolution,
            frameRate: .fps24,
            quality: .low,
            transitionDuration: project.transitionDuration,
            photoDuration: project.defaultPhotoDuration,
            outputURL: outputURL
        )
        try SlideshowExporter(project: project, request: request).export()
        return outputURL
    }

    /// Короткий экспорт: файл существует, длительность соответствует таймлайну,
    /// есть видео-дорожка.
    func testExportProducesValidVideo() throws {
        let project = try makeProject(photoCount: 2)
        let outputURL = try runExport(project: project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
        // Таймлайн: слайд 0 = 0...2, слайд 1 стартует в 1.5 → итог 3.5 c.
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 3.5, accuracy: 0.2)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty)

        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Длинный экспорт (20+ с видео, сотни кадров) — регрессия утечки памяти
    /// в цикле записи кадров (краш на ~30 с). Завершение без краша и корректная
    /// длительность — главный критерий.
    func testLongExportCompletesWithoutMemoryGrowthCrash() throws {
        let project = try makeProject(photoCount: 8, photoDuration: 3, transitionDuration: 0.5)
        let outputURL = try runExport(project: project)

        let asset = AVURLAsset(url: outputURL)
        // Таймлайн: 8 фото по 3 c с перекрытием 0.5 c: 3 + 7*2.5 = 20.5 c.
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 20.5, accuracy: 0.2)

        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Регрессия «cannot open video asset frame at 29,9s»: видео с аудио
    /// длиннее видеодорожки. Длительность слайда берётся по видеодорожке,
    /// экспорт завершается без ошибок.
    func testExportWithVideoWhoseAudioIsLongerThanVideo() throws {
        let dir = FileManager.default.temporaryDirectory
        let baseURL = dir.appendingPathComponent("lumi-exp-tail-base-\(UUID().uuidString).mp4")
        let wavURL = dir.appendingPathComponent("lumi-exp-tail-\(UUID().uuidString).wav")
        let muxURL = dir.appendingPathComponent("lumi-exp-tail-mux-\(UUID().uuidString).mp4")
        let outputURL = dir.appendingPathComponent("lumi-exp-tail-out-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: muxURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try TestMediaFactory.makeBaseVideo(url: baseURL, duration: 5)   // видео 5 c
        try TestMediaFactory.writeWAV(url: wavURL, duration: 7)          // аудио 7 c
        try TestMediaFactory.mux(videoURL: baseURL, audioURL: wavURL, out: muxURL)

        var project = SlideshowProject(name: "Tail Export")
        project.defaultPhotoDuration = 2
        project.transitionDuration = 0.5
        project.isKenBurnsEnabled = false
        project.slides = [
            try MediaReference(kind: .video, bookmarkData: BookmarkResolver.createBookmark(for: muxURL), displayName: "v1"),
        ]

        let request = ExportRequest(
            codec: .h264,
            resolution: CGSize(width: 320, height: 180),
            frameRate: .fps24,
            quality: .low,
            transitionDuration: 0.5,
            photoDuration: 2,
            outputURL: outputURL
        )
        try SlideshowExporter(project: project, request: request).export()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
        // Длительность итога ≈ длительность видеодорожки (5 c), а не 7 c.
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 5.0, accuracy: 0.3)
    }
}
