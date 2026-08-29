import XCTest
import Foundation
import CoreImage
import AVFoundation
@testable import SlideStoryRenderer
@testable import SlideStoryModel

final class RendererLogicTests: XCTestCase {

    // MARK: - TimelineBuilder

    private func makeProject(slides: [MediaKind], photoDuration: Double = 5.0, transitionDuration: Double = 1.0) -> SlideshowProject {
        var project = SlideshowProject()
        project.defaultPhotoDuration = photoDuration
        project.transitionDuration = transitionDuration
        project.slides = slides.map { MediaReference(kind: $0, bookmarkData: "bm", displayName: "x") }
        return project
    }

    func testTimelineBuilder_AllPhotos() {
        let project = makeProject(slides: [.photo, .photo, .photo])
        let timeline = TimelineBuilder.buildTimeline(project: project)
        XCTAssertEqual(timeline.count, 3)
        // Слайд 0: 0...5, слайд 1 начинается за 1 c до конца: 4, слайд 2: 8.
        XCTAssertEqual(timeline[0].startTime, 0)
        XCTAssertEqual(timeline[0].endTime, 5)
        XCTAssertEqual(timeline[1].startTime, 4)
        XCTAssertEqual(timeline[2].startTime, 8)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: timeline), 13, accuracy: 0.001)
    }

    func testTimelineBuilder_TransitionClampedToSlideDuration() {
        // Переход 10 c, слайд 5 c → длительность перехода клампится до 5.
        let project = makeProject(slides: [.photo, .photo], photoDuration: 5, transitionDuration: 10)
        let timeline = TimelineBuilder.buildTimeline(project: project)
        XCTAssertEqual(timeline[0].transitionDuration, 5, accuracy: 0.001)
        XCTAssertEqual(timeline[1].startTime, 0, accuracy: 0.001)
    }

    func testTimelineBuilder_VideoDurations() {
        let project = makeProject(slides: [.video, .video])
        let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: [0: 3.0, 1: 4.0])
        // Слайд 0: 0...3 (переход 1c), слайд 1 начинается в 2 и длится 4c → конец 6.
        XCTAssertEqual(timeline[0].endTime, 3.0, accuracy: 0.001)
        XCTAssertEqual(timeline[1].startTime, 2.0, accuracy: 0.001)
        XCTAssertEqual(timeline[1].endTime, 6.0, accuracy: 0.001)
    }

    func testTimelineBuilder_SlideLookup() {
        let project = makeProject(slides: [.photo, .photo])
        let timeline = TimelineBuilder.buildTimeline(project: project)
        // Перекрытие: слайд 1 начинается в 4 (за 1c до конца слайда 0 = 5).
        // 4.5 — зона перехода: владеет слайд 0 (текущий), 5.5 — уже слайд 1.
        let duringTransition = TimelineBuilder.slide(at: 4.5, in: timeline)
        XCTAssertEqual(duringTransition?.item.slideIndex, 0)
        let afterTransition = TimelineBuilder.slide(at: 5.5, in: timeline)
        XCTAssertEqual(afterTransition?.item.slideIndex, 1)
    }

    // MARK: - KenBurnsPlanner

    func testKenBurnsDeterministic() {
        let a = KenBurnsPlanner.trajectory(seed: 42, slideIndex: 0, duration: 5, faceRegions: [])
        let b = KenBurnsPlanner.trajectory(seed: 42, slideIndex: 0, duration: 5, faceRegions: [])
        XCTAssertEqual(a.startRect, b.startRect)
        XCTAssertEqual(a.endRect, b.endRect)
    }

    func testKenBurnsAnimatesOverTime() {
        let trajectory = KenBurnsPlanner.trajectory(seed: 1, slideIndex: 0, duration: 5, faceRegions: [])
        let start = trajectory.rect(atTime: 0)
        let middle = trajectory.rect(atTime: 0.5)
        let end = trajectory.rect(atTime: 1)
        // Траектория должна двигаться: rect на разных моментах различается.
        XCTAssertNotEqual(start, middle)
        XCTAssertNotEqual(middle, end)
        // Интерполяция линейная: середина между start и end.
        XCTAssertEqual(middle.origin.x, (start.origin.x + end.origin.x) / 2, accuracy: 0.001)
        XCTAssertEqual(middle.width, (start.width + end.width) / 2, accuracy: 0.001)
    }

    func testKenBurnsFaceCentersInterestPoint() {
        // Лицо в левом нижнем углу — точка интереса должна сместиться туда.
        let face = [FaceRegion(x: 0.0, y: 0.0, width: 0.2, height: 0.2)]
        let withFace = KenBurnsPlanner.trajectory(seed: 1, slideIndex: 0, duration: 5, faceRegions: face)
        let withoutFace = KenBurnsPlanner.trajectory(seed: 1, slideIndex: 0, duration: 5, faceRegions: [])
        XCTAssertNotEqual(withFace.startRect, withoutFace.startRect)
    }

    func testKenBurnsRectsWithinBounds() {
        for seed in 0..<50 {
            let t = KenBurnsPlanner.trajectory(seed: UInt64(seed), slideIndex: seed, duration: 5, faceRegions: [])
            for time in [0.0, 0.5, 1.0] {
                let r = t.rect(atTime: time)
                XCTAssertGreaterThanOrEqual(r.minX, 0)
                XCTAssertGreaterThanOrEqual(r.minY, 0)
                XCTAssertLessThanOrEqual(r.maxX, 1.0001)
                XCTAssertLessThanOrEqual(r.maxY, 1.0001)
            }
        }
    }

    // MARK: - TransitionBlender (Metal)

    func testMetalTransitionBlenderInitializes() throws {
        // Воспроизводит сценарий краша: инициализация TransitionBlender
        // вызывала Bundle.module, который падает с fatalError при отсутствии
        // ресурсного бандла. Теперь должен безопасно загрузить шейдеры
        // (из бандла или из встроенной строки).
        for type in TransitionType.transitionOrder where type.backend == .metal {
            let blender = try TransitionBlender(transitionType: type)
            XCTAssertNotNil(blender, "Blender для \(type.rawValue) не создан")
        }
    }

    func testMetalTransitionRendersFrame() throws {
        // Реальный рендер кадра с Metal-переходом: проверяет, что
        // кернел компилируется и корректно исполняется на двух кадрах.
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 64, height: 64,
            bitsPerComponent: 8, bytesPerRow: 0, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let red = CIImage(cgImage: context.makeImage()!)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let blue = CIImage(cgImage: context.makeImage()!)

        for type in TransitionType.transitionOrder where type.backend == .metal {
            let blender = try TransitionBlender(transitionType: type)
            let output = try blender.blendMetal(fromImage: red, toImage: blue, progress: 0.5)
            XCTAssertFalse(output.extent.isEmpty, "Кадр \(type.rawValue) пуст")
        }
    }

    // MARK: - Интеграция: превью (фото + переходы)

    func testPreviewPlaybackRendersAllFrames() throws {
        // Воспроизводит сценарий краша «при воспроизведении слайдшоу»:
        // рендерит кадры по всему таймлайну, включая все типы переходов.
        let demoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Lumislide-Demo", isDirectory: true)
        let photoURLs = ["photo1.jpg", "photo2.jpg", "photo3.jpg"].map {
            demoDir.appendingPathComponent($0)
        }
        guard photoURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Демо-файлы не найдены")
        }

        var project = SlideshowProject(name: "Playback Test", transitionSeed: 42)
        project.defaultPhotoDuration = 2.0
        project.transitionDuration = 1.0
        project.slides = try photoURLs.map { url in
            MediaReference(
                kind: .photo,
                bookmarkData: try BookmarkResolver.createBookmark(for: url),
                displayName: url.lastPathComponent
            )
        }

        let timeline = TimelineBuilder.buildTimeline(project: project)
        let duration = TimelineBuilder.totalDuration(of: timeline)

        // Перебираем все типы переходов — каждый проигрываем полностью.
        for forced in TransitionType.transitionOrder {
            var p = project
            p.slides[0].transitionOverride = forced

            let renderer = TimelineFrameRenderer(
                configuration: RenderFrameConfiguration(
                    canvasSize: CGSize(width: 960, height: 540),
                    renderScale: 0.5
                )
            )
            let ciContext = CIContext()

            // Шаг как в предпросмотре (20 fps), но прореженный для скорости.
            var t: Double = 0
            while t < duration {
                let frame = try renderer.makeFrame(at: t, timeline: timeline, project: p)
                _ = ciContext.createCGImage(frame, from: frame.extent)
                t += 0.25
            }
        }
    }

    // MARK: - Длительность видео-слайдов (проблема 3)

    func testVideoSlideUsesActualDuration() throws {
        // Видео-слайд должен длиться столько, сколько идёт исходный файл,
        // а не как фото (defaultPhotoDuration).
        let demoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Lumislide-Demo", isDirectory: true)
        let videoURL = demoDir.appendingPathComponent("clip.mp4")
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw XCTSkip("Тестовое видео clip.mp4 не найдено")
        }

        // Длительность источника (8 c).
        let asset = AVURLAsset(url: videoURL)
        let sourceDuration = asset.duration.seconds

        var project = SlideshowProject(name: "Video Test", transitionSeed: 1)
        project.defaultPhotoDuration = 3.0 // короче видео — таймлайн не должен её использовать
        project.transitionDuration = 0
        project.slides = [
            MediaReference(
                kind: .video,
                bookmarkData: try BookmarkResolver.createBookmark(for: videoURL),
                displayName: videoURL.lastPathComponent
            ),
        ]

        // Превью резолвит фактические длительности (как PreviewRenderer).
        var videoDurations: [Int: Double] = [:]
        if let resolved = try? BookmarkResolver.resolve(project.slides[0].bookmarkData),
           let source = try? VideoFrameSource(url: resolved.url, accessHolder: resolved.accessHolder) {
            videoDurations[0] = source.duration
        }
        let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: videoDurations)

        XCTAssertEqual(videoDurations[0] ?? 0, sourceDuration, accuracy: 0.5)
        // Слайд длится как видео (8 c), а не 3 c как фото.
        XCTAssertEqual(timeline[0].duration, sourceDuration, accuracy: 0.5)
        XCTAssertGreaterThan(timeline[0].duration, project.defaultPhotoDuration)
    }


    func testMusicPlannerFallbackToPhotoDuration() {
        let kinds: [MediaKind] = [.photo]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: [0],
            slideEndTimes: [5],
            transitionDurations: [0]
        )
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].duration, 5, accuracy: 0.001)
    }

    // MARK: - FaceDetector

    func testFaceDetectorReturnsEmptyForSolidImage() throws {
        // Синтетическое изображение без лиц: детектор должен вернуть [].
        let width = 320
        let height = 240
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let image = CIImage(cgImage: cgImage)
        let faces = try FaceDetector.detectFacesSync(in: image)
        XCTAssertTrue(faces.isEmpty, "На однотонном изображении лиц быть не должно")
    }

    // MARK: - AudioTrackMixer.photoIntervals (интеграция с таймлайном)

    func testProjectPhotoIntervalsIntegratesWithTimeline() {
        var project = SlideshowProject(transitionSeed: 5)
        project.defaultPhotoDuration = 5
        project.transitionDuration = 1
        project.slides = [
            MediaReference(kind: .photo, bookmarkData: "1", displayName: "1"),
            MediaReference(kind: .video, bookmarkData: "2", displayName: "2"),
            MediaReference(kind: .photo, bookmarkData: "3", displayName: "3"),
        ]
        let timeline = TimelineBuilder.buildTimeline(project: project)
        XCTAssertEqual(timeline.count, 3)

        let intervals = AudioTrackMixer.photoIntervals(project: project, timeline: timeline)
        // Фото 0: 0...5 → музыке нужно замолкнуть за 2 c до видео (начинается в 4):
        // интервал 0...2.
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(intervals[0].end, 2, accuracy: 0.001)
        // После видео (заканчивается в 9) фото снова звучит с 9 до конца (13+...):
        // слайд 2: 8...13, но следующий видео нет → интервал 9...13? Начинается с 8
        // (момент старта слайда 2 = 8), уточним в тесте по фактическому таймлайну.
        XCTAssertEqual(intervals[1].start, timeline[2].startTime, accuracy: 0.001)
        XCTAssertEqual(intervals[1].end, timeline[2].endTime, accuracy: 0.001)
    }
}
