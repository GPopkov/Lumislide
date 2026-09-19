import XCTest
import Foundation
import CoreImage
import ImageIO
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

    func testKenBurnsFaceFocusesOnFace() {
        // Лицо справа-снизу — траектория должна заканчиваться вблизи него,
        // а не зумить по центру кадра.
        let face = [FaceRegion(x: 0.7, y: 0.6, width: 0.2, height: 0.25)]
        let unionCenter = CGPoint(x: 0.8, y: 0.725)
        let withFace = KenBurnsPlanner.trajectory(seed: 1, slideIndex: 0, duration: 5, faceRegions: face)

        // Старт — весь кадр (контекст), затем зум к лицу.
        XCTAssertEqual(withFace.startRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        // Конечный кадр центрирован на лице (с учётом clamp по краям).
        let endCenter = CGPoint(x: withFace.endRect.midX, y: withFace.endRect.midY)
        XCTAssertLessThan(abs(endCenter.x - unionCenter.x), 0.15,
                          "Конец движения должен быть у лица по X")
        XCTAssertLessThan(abs(endCenter.y - unionCenter.y), 0.15,
                          "Конец движения должен быть у лица по Y")
        XCTAssertTrue(withFace.endRect.contains(unionCenter),
                      "Центр объединения лиц должен попадать в конечный кадр")
        // Без лиц (правило третей) конечный центр иной — фокус реально работает.
        let withoutFace = KenBurnsPlanner.trajectory(seed: 1, slideIndex: 0, duration: 5, faceRegions: [])
        let thirdsCenter = CGPoint(x: withoutFace.endRect.midX, y: withoutFace.endRect.midY)
        XCTAssertNotEqual(endCenter, thirdsCenter)
    }

    func testMapFacesToCanvasLandscapeImage() {
        // Фото 3000×2250 (4:3) в холсте 1920×1080 (16:9): fit-полоса 1440×1080
        // по центру по X. Лицо в левом верхнем углу изображения (0,0,0.1,0.1).
        let mapped = TimelineFrameRenderer.mapFacesToCanvas(
            [FaceRegion(x: 0.0, y: 0.0, width: 0.1, height: 0.1)],
            imageSize: CGSize(width: 3000, height: 2250),
            canvasSize: CGSize(width: 1920, height: 1080)
        )
        let face = mapped[0]
        XCTAssertEqual(face.x, 240.0 / 1920.0, accuracy: 0.001)   // offsetX = (1920-1440)/2
        XCTAssertEqual(face.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(face.width, 144.0 / 1920.0, accuracy: 0.001)
        XCTAssertEqual(face.height, 0.1, accuracy: 0.001)
    }

    func testMapFacesToCanvasPortraitImage() {
        // Портрет 2250×3000 в холсте 1920×1080: fit 810×1080 по центру.
        let mapped = TimelineFrameRenderer.mapFacesToCanvas(
            [FaceRegion(x: 0.5, y: 0.5, width: 0.1, height: 0.1)],
            imageSize: CGSize(width: 2250, height: 3000),
            canvasSize: CGSize(width: 1920, height: 1080)
        )
        let face = mapped[0]
        XCTAssertEqual(face.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(face.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(face.width, 81.0 / 1920.0, accuracy: 0.001)
        XCTAssertEqual(face.height, 0.1, accuracy: 0.001)
    }

    func testKenBurnsRectsWithinBoundsWithFaces() {
        // Конечные кадры при лицах у краёв не выходят за границы (0...1).
        let edgeFaces = [
            FaceRegion(x: 0.0, y: 0.0, width: 0.12, height: 0.12),
            FaceRegion(x: 0.88, y: 0.88, width: 0.12, height: 0.12),
            FaceRegion(x: 0.0, y: 0.88, width: 0.1, height: 0.1),
        ]
        for face in edgeFaces {
            let t = KenBurnsPlanner.trajectory(seed: 3, slideIndex: 1, duration: 5, faceRegions: [face])
            for rect in [t.startRect, t.endRect] {
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxX, 1.0001)
                XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
            }
        }
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

    func testPerSlideDurationAndPlayFullVideo() {
        var project = SlideshowProject(transitionSeed: 3)
        project.defaultPhotoDuration = 5
        project.transitionDuration = 0
        project.slides = [
            MediaReference(kind: .photo, bookmarkData: "1", displayName: "p1", customDuration: 7),
            MediaReference(kind: .video, bookmarkData: "2", displayName: "v1", playFullVideo: true),
            MediaReference(kind: .video, bookmarkData: "3", displayName: "v2", customDuration: 2, playFullVideo: false),
        ]
        let videoDurations: [Int: Double] = [1: 10, 2: 10]
        let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: videoDurations)
        XCTAssertEqual(timeline.count, 3)
        XCTAssertEqual(timeline[0].duration, 7, accuracy: 0.001)
        XCTAssertEqual(timeline[1].duration, 10, accuracy: 0.001)
        XCTAssertEqual(timeline[2].duration, 2, accuracy: 0.001)
    }

    /// Регрессия по памяти: кэши рендерера (источники, «базы» фото, титры)
    /// должны быть ограничены, иначе память экспорта растёт с числом слайдов.
    func testRendererCachesStayBounded() throws {
        let dir = FileManager.default.temporaryDirectory
        var files: [URL] = []
        defer { for f in files { try? FileManager.default.removeItem(at: f) } }

        var project = SlideshowProject(name: "Caches")
        project.defaultPhotoDuration = 0.5
        project.transitionDuration = 0.2
        project.isKenBurnsEnabled = false
        var slides: [MediaReference] = []
        for i in 0..<14 {
            let url = dir.appendingPathComponent("lumi-cache-\(i)-\(UUID().uuidString).png")
            files.append(url)
            let ctx = CGContext(
                data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(srgbRed: CGFloat(i % 5) / 5, green: 0.5, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { throw XCTSkip("cannot create test image") }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
            slides.append(MediaReference(kind: .photo, bookmarkData: try BookmarkResolver.createBookmark(for: url), displayName: url.lastPathComponent))
        }
        project.slides = slides

        let renderer = TimelineFrameRenderer(
            configuration: RenderFrameConfiguration(
                canvasSize: CGSize(width: 640, height: 360),
                renderScale: 0.5,
                sourceMaxPixelSize: 1200,
                maxCachedSources: 4,
                maxCachedPhotoBases: 3
            )
        )
        let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: [:])
        let total = TimelineBuilder.totalDuration(of: timeline)

        var time = 0.0
        while time <= total {
            _ = try renderer.makeFrame(at: time, timeline: timeline, project: project)
            time += 0.1
        }

        let counts = renderer.cacheCounts
        XCTAssertLessThanOrEqual(counts.sources, 4, "Кэш источников не ограничен")
        XCTAssertLessThanOrEqual(counts.photoBases, 3, "Кэш «баз» фото не ограничен")
    }

    /// Регрессия: «скольжение влево/вправо» должно идти по всему времени
    /// перехода и одинаково работать на любом размере холста. Раньше
    /// (CISwipeTransition, width = 0) в экспорте эффект заканчивался за ~20%
    /// времени перехода и картинка «прыгала».
    func testSlideTransitionProgressIsGradualAtAnyCanvasSize() throws {
        let dir = FileManager.default.temporaryDirectory
        var files: [URL] = []
        defer { for f in files { try? FileManager.default.removeItem(at: f) } }

        func makeSolidPhoto(red: CGFloat, blue: CGFloat, name: String) throws -> MediaReference {
            let url = dir.appendingPathComponent("lumi-slide-\(name)-\(UUID().uuidString).png")
            files.append(url)
            let ctx = CGContext(
                data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            let image = ctx.makeImage()!
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw XCTSkip("cannot create test image")
            }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
            return MediaReference(
                kind: .photo,
                bookmarkData: try BookmarkResolver.createBookmark(for: url),
                displayName: name
            )
        }

        for canvasHeight in [270.0, 1080.0] {
            var project = SlideshowProject(name: "Slide")
            project.defaultPhotoDuration = 2
            project.transitionDuration = 1
            project.isKenBurnsEnabled = false
            var first = try makeSolidPhoto(red: 1, blue: 0, name: "red")
            first.transitionOverride = .slideLeft
            project.slides = [first, try makeSolidPhoto(red: 0, blue: 1, name: "blue")]

            let canvas = project.exportSettings.aspectRatio.canvasSize(height: CGFloat(canvasHeight))
            let renderer = TimelineFrameRenderer(
                configuration: RenderFrameConfiguration(canvasSize: canvas, renderScale: 1.0)
            )
            let timeline = TimelineBuilder.buildTimeline(project: project, videoDurations: [:])
            XCTAssertEqual(timeline.count, 2)
            let transitionDuration = timeline[0].transitionDuration
            XCTAssertGreaterThan(transitionDuration, 0)
            let transitionStart = timeline[0].endTime - transitionDuration

            func redShare(at progress: Double) -> Double {
                let time = transitionStart + progress * transitionDuration * 0.999
                guard let frame = try? renderer.makeFrame(at: time, timeline: timeline, project: project),
                      let cg = CIContext().createCGImage(frame, from: frame.extent) else { return -1 }
                return Self.redShare(of: cg)
            }

            let start = redShare(at: 0.0)
            let middle = redShare(at: 0.5)
            let finish = redShare(at: 0.999)
            XCTAssertGreaterThan(start, 0.9, "canvas \(canvasHeight): начало перехода не показывает первый слайд")
            XCTAssertLessThan(finish, 0.1, "canvas \(canvasHeight): конец перехода не показывает второй слайд")
            XCTAssertGreaterThan(middle, 0.15, "canvas \(canvasHeight): эффект пролетает (середина = финал)")
            XCTAssertLessThan(middle, 0.85, "canvas \(canvasHeight): эффект не идёт (середина = начало)")
        }
    }

    /// Доля «красных» пикселей (для проверки постепенности перехода).
    private static func redShare(of image: CGImage) -> Double {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0
        var index = 0
        while index < pixels.count {
            if pixels[index] > 128, pixels[index + 2] < 128 { red += 1 }
            index += 4
        }
        return Double(red) / Double(width * height)
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
        // Фото 0: 0...5 → музыке нужно замолкнуть за 1 c до видео (начинается в 4):
        // интервал 0...3.
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(intervals[0].end, 3, accuracy: 0.001)
        // После видео (заканчивается в 9) фото снова звучит с 9 до конца (13+...):
        // слайд 2: 8...13, но следующий видео нет → интервал 9...13? Начинается с 8
        // (момент старта слайда 2 = 8), уточним в тесте по фактическому таймлайну.
        XCTAssertEqual(intervals[1].start, timeline[2].startTime, accuracy: 0.001)
        XCTAssertEqual(intervals[1].end, timeline[2].endTime, accuracy: 0.001)
    }
}
