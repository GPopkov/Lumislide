import XCTest
import Foundation
@testable import SlideStoryModel

final class ModelTests: XCTestCase {

    // MARK: - TransitionPicker

    func testTransitionPickerIsDeterministic() {
        let seed: UInt64 = 0x123456789ABCDEF0
        let first = (0..<100).map { TransitionPicker.transition(seed: seed, slideIndex: $0) }
        let second = (0..<100).map { TransitionPicker.transition(seed: seed, slideIndex: $0) }
        XCTAssertEqual(first, second, "Переходы должны быть детерминированы по seed")
    }

    func testTransitionPickerDifferentSlidesMayDiffer() {
        let seed: UInt64 = 42
        let a = TransitionPicker.transition(seed: seed, slideIndex: 0)
        let b = TransitionPicker.transition(seed: seed, slideIndex: 7)
        // Не гарантируем различие, но проверим, что оба в списке.
        XCTAssertTrue(TransitionType.transitionOrder.contains(a))
        XCTAssertTrue(TransitionType.transitionOrder.contains(b))
    }

    func testTransitionPickerCoversAllElevenTypes() {
        let seed: UInt64 = 0xDEADBEEF
        var seen = Set<TransitionType>()
        for index in 0..<10_000 {
            seen.insert(TransitionPicker.transition(seed: seed, slideIndex: index))
        }
        XCTAssertEqual(seen.count, 11, "Генератор должен покрывать все 11 типов переходов")
    }

    func testCanonicalIndexRoundTrip() {
        for type in TransitionType.transitionOrder {
            let idx = type.canonicalIndex
            XCTAssertEqual(TransitionType(canonicalIndex: idx), type)
        }
    }

    func testElevenTransitions() {
        XCTAssertEqual(TransitionType.allCases.count, 11)
        XCTAssertEqual(TransitionType.transitionOrder.count, 11)
    }

    // MARK: - Project

    func testProjectSaveAndLoadRoundTrip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.slideshow")

        var project = SlideshowProject(name: "Demo")
        project.slides = [
            MediaReference(kind: .photo, bookmarkData: "AAA", displayName: "IMG_0001.HEIC"),
            MediaReference(kind: .video, bookmarkData: "BBB", displayName: "VID_0001.MOV"),
        ]
        project.slides[0].transitionOverride = .door
        project.slides[0].titleOverlay = TitleOverlay(text: "Hello", position: .bottom)
        project.music = MusicSettings(source: .userFile(
            MediaAudioReference(bookmarkData: "CCC", displayName: "track.mp3")
        ), volume: 0.5)

        let store = ProjectStore(fileURL: url)
        try store.save(project)

        let loaded = try store.load()
        XCTAssertEqual(loaded.name, "Demo")
        XCTAssertEqual(loaded.slides.count, 2)
        XCTAssertEqual(loaded.slides[0].kind, .photo)
        XCTAssertEqual(loaded.slides[0].transitionOverride, .door)
        XCTAssertEqual(loaded.slides[0].titleOverlay?.text, "Hello")
        XCTAssertEqual(loaded.transitionSeed, project.transitionSeed)
        XCTAssertEqual(loaded.music.volume, 0.5, accuracy: 0.001)
        guard case .userFile(let audio) = loaded.music.source else {
            return XCTFail("Ожидалась userFile музыка")
        }
        XCTAssertEqual(audio.displayName, "track.mp3")
    }

    func testProjectTransitionOverrideWinsOverSeed() {
        var project = SlideshowProject(transitionSeed: 7)
        project.slides = [
            MediaReference(kind: .photo, bookmarkData: "A", displayName: "1"),
            MediaReference(kind: .photo, bookmarkData: "B", displayName: "2"),
        ]
        project.slides[0].transitionOverride = .grid
        XCTAssertEqual(project.transitionType(at: 0), .grid)
    }

    func testProjectTransitionAutoUsesSeed() {
        let project = SlideshowProject(
            slides: [
                MediaReference(kind: .photo, bookmarkData: "A", displayName: "1"),
                MediaReference(kind: .photo, bookmarkData: "B", displayName: "2"),
            ],
            transitionSeed: 123
        )
        let t = project.transitionType(at: 0)
        XCTAssertEqual(t, TransitionPicker.transition(seed: 123, slideIndex: 0))
        XCTAssertNotNil(t)
    }

    func testProjectLastSlideHasNoTransition() {
        let project = SlideshowProject(slides: [.init(kind: .photo, bookmarkData: "A", displayName: "1")])
        XCTAssertNil(project.transitionType(at: 0))
    }

    func testMoveSlide() {
        var project = SlideshowProject()
        project.slides = [
            MediaReference(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .photo, bookmarkData: "1", displayName: "1"),
            MediaReference(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, kind: .photo, bookmarkData: "2", displayName: "2"),
            MediaReference(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, kind: .photo, bookmarkData: "3", displayName: "3"),
        ]
        project.moveSlide(from: 0, to: 2)
        XCTAssertEqual(project.slides.map(\.displayName), ["2", "3", "1"])
    }

    func testRemoveSlide() {
        let id = UUID()
        var project = SlideshowProject(slides: [
            MediaReference(id: id, kind: .photo, bookmarkData: "1", displayName: "1"),
            MediaReference(kind: .photo, bookmarkData: "2", displayName: "2"),
        ])
        let removed = project.removeSlide(id: id)
        XCTAssertTrue(removed)
        XCTAssertEqual(project.slides.count, 1)
    }

    // MARK: - Seed

    func testSeedStoredAsString_NoPrecisionLoss() {
        let bigSeed: UInt64 = 0xFEDCBA9876543210
        let project = SlideshowProject(transitionSeed: bigSeed)
        XCTAssertEqual(project.transitionSeedValue, bigSeed)

        let jsonDecoder = JSONDecoder()
        let jsonEncoder = JSONEncoder()
        let data = try! jsonEncoder.encode(project)
        let decoded = try! jsonDecoder.decode(SlideshowProject.self, from: data)
        XCTAssertEqual(decoded.transitionSeedValue, bigSeed)
    }

    // MARK: - Music Timeline Planner

    func testMusicPlanner_AllPhotos() {
        // 3 фото подряд, длительность каждого 5 c, переход 1 c.
        let kinds: [MediaKind] = [.photo, .photo, .photo]
        let starts: [Double] = [0, 4, 8]
        let ends: [Double] = [5, 9, 13]
        let transitions: [Double] = [1, 1, 0]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: starts,
            slideEndTimes: ends,
            transitionDurations: transitions
        )
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, 0)
        XCTAssertEqual(intervals[0].end, 13)
    }

    func testMusicPlanner_AllVideos() {
        let kinds: [MediaKind] = [.video, .video]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: [0, 5],
            slideEndTimes: [5, 10],
            transitionDurations: [0, 0]
        )
        XCTAssertTrue(intervals.isEmpty, "Если проект состоит только из видео — музыка не звучит")
    }

    func testMusicPlanner_PhotoThenVideo() {
        // Фото 0...5, затем видео 4...9 (переход 1 c).
        let kinds: [MediaKind] = [.photo, .video]
        let starts: [Double] = [0, 4]
        let ends: [Double] = [5, 9]
        let transitions: [Double] = [1, 0]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: starts,
            slideEndTimes: ends,
            transitionDurations: transitions
        )
        // Трек должен замолкнуть за fade (2 c) до старта видео = 4 - 2 = 2 c.
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, 0)
        XCTAssertEqual(intervals[0].end, 2, accuracy: 0.001)
    }

    func testMusicPlanner_VideoThenPhoto() {
        // Видео 0...6, затем фото 6...11.
        let kinds: [MediaKind] = [.video, .photo]
        let starts: [Double] = [0, 6]
        let ends: [Double] = [6, 11]
        let transitions: [Double] = [0, 0]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: starts,
            slideEndTimes: ends,
            transitionDurations: transitions
        )
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, 6)
        XCTAssertEqual(intervals[0].end, 11)
    }

    func testMusicPlanner_Mixed() {
        // фото, видео, фото, фото, видео
        let kinds: [MediaKind] = [.photo, .video, .photo, .photo, .video]
        let starts: [Double] = [0, 4, 9, 13, 17]
        let ends: [Double] = [5, 9, 14, 18, 22]
        let transitions: [Double] = [1, 0, 1, 1, 0]
        let intervals = MusicTimelinePlanner.photoIntervals(
            slideKinds: kinds,
            slideStartTimes: starts,
            slideEndTimes: ends,
            transitionDurations: transitions
        )
        // Интервал 1: 0...4-fade(2) = 2
        // Интервал 2: после видео (start 9) ... до начала следующего видео (17) - fade:
        //   фото 2 (9...14), фото 3 (13...18) — заканчивается на 17-2=15.
        //   Итого: 9...15.
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, 0)
        XCTAssertEqual(intervals[0].end, 2, accuracy: 0.001)
        XCTAssertEqual(intervals[1].start, 9)
        XCTAssertEqual(intervals[1].end, 15, accuracy: 0.001)
    }

    // MARK: - FaceRegion

    func testFaceRegionUnion() {
        let regions = [
            FaceRegion(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
            FaceRegion(x: 0.5, y: 0.4, width: 0.2, height: 0.3),
        ]
        let union = FaceRegion.union(of: regions)
        XCTAssertEqual(union?.x ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(union?.width ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(union?.height ?? 0, 0.6, accuracy: 0.001)
    }

    func testFaceRegionUnionEmpty() {
        XCTAssertNil(FaceRegion.union(of: []))
    }

    // MARK: - Aspect Ratio

    func testAspectRatioCanvasSize() {
        let size = AspectRatio.landscape16x9.canvasSize(height: 1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testAspectRatioPresets() {
        XCTAssertEqual(AspectRatio.square1x1.presets.count, 3)
        XCTAssertEqual(AspectRatio.portrait9x16.presets[1].size.height, 1920)
    }

    // MARK: - Сессионный доступ к свежим bookmark'ам

    func testSessionURLBypassesBookmarkResolution() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session-photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)

        // Регистрируем исходный URL за НЕВАЛИДНЫМ bookmark (имитация: свежий
        // bookmark, который в текущей сессии ещё «не работает»).
        let invalidBookmark = "!!!not-a-valid-bookmark!!!"
        BookmarkResolver.registerSessionURL(url, forBookmark: invalidBookmark)

        // Резолвинг должен вернуть зарегистрированный URL без разбора
        // bookmark-данных.
        let resolved = try BookmarkResolver.resolve(invalidBookmark)
        XCTAssertEqual(resolved.url.standardizedFileURL, url.standardizedFileURL)

        let plainURL = try BookmarkResolver.url(fromBookmark: invalidBookmark)
        XCTAssertEqual(plainURL.standardizedFileURL, url.standardizedFileURL)

        // Настоящий валидный bookmark НЕ должен резолвиться через реестр.
        let realBookmark = try BookmarkResolver.createBookmark(for: url)
        let resolvedReal = try BookmarkResolver.resolve(realBookmark)
        XCTAssertEqual(resolvedReal.url.standardizedFileURL, url.standardizedFileURL)
    }

    func testSessionURLIgnoredWhenFileMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Файл существует на момент регистрации, затем удаляется.
        let url = dir.appendingPathComponent("gone.jpg")
        try Data([0xFF, 0xD8]).write(to: url)
        let invalidBookmark = "%%%no-such-bookmark%%%"
        BookmarkResolver.registerSessionURL(url, forBookmark: invalidBookmark)
        try? fm.removeItem(at: url)

        // Файл недоступен — реестр не должен «выдавать» мёртвый URL.
        XCTAssertThrowsError(try BookmarkResolver.resolve(invalidBookmark))
    }
}