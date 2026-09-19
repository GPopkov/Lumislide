import SwiftUI
import AppKit
import CoreImage
import Combine
import SlideStoryModel
import SlideStoryRenderer

/// Окно увеличенного просмотра одного слайда (открывается двойным щелчком
/// по карточке). Слайды листаются стрелками (← → ↑ ↓), Home/End, Esc — закрыть.
final class SlideViewerWindow: EscCloseWindow {
    /// Обработчик клавиш: возвращает true, если событие обработано.
    var onKeyDown: ((UInt16) -> Bool)?

    /// Перехватываем клавиши в `sendEvent`, а не в `keyDown`: SwiftUI-хост
    /// (NSHostingView) сам обрабатывает стрелки и не выпускает их дальше по
    /// цепочке ответчиков, поэтому `keyDown` окна не вызывается.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKeyDown, onKeyDown(event.keyCode) {
            return
        }
        super.sendEvent(event)
    }
}

/// Модель окна просмотра: рендерит выбранный слайд в крупном размере
/// и управляет навигацией по слайдам проекта.
@MainActor
final class SlideViewerModel: ObservableObject {
    @Published private(set) var index: Int
    @Published private(set) var image: NSImage?
    @Published private(set) var isRendering = false
    @Published private(set) var slideCount = 0
    @Published private(set) var slideName = ""

    private let store: ProjectsStore
    private var project: SlideshowProject?
    private var timeline: [SlideTimelineItem] = []
    private var renderer: TimelineFrameRenderer?
    private var signature = ""

    /// Рендер кадра — на фоне (не блокируем главный поток).
    private let renderQueue = DispatchQueue(label: "com.lumislide.slide-viewer.render", qos: .userInitiated)
    private let ciContext = CIContext()
    /// Токен актуального запроса (устаревшие результаты отбрасываются).
    private var currentToken = 0
    private var cancellable: AnyCancellable?

    /// Высота холста рендера окна просмотра.
    private static let canvasHeight: CGFloat = 1080

    init(store: ProjectsStore, startIndex: Int) {
        self.store = store
        self.index = max(startIndex, 0)
        update(project: store.currentProject)
        // Реагируем на изменения проекта (правки, добавление/удаление слайдов).
        cancellable = store.$currentProject.sink { [weak self] project in
            Task { @MainActor in self?.update(project: project) }
        }
    }

    /// Текст позиции («3 / 24»).
    var positionText: String {
        slideCount == 0 ? "0 / 0" : "\(index + 1) / \(slideCount)"
    }

    // MARK: - Навигация

    /// Удаляет текущий слайд (Delete/Backspace в окне просмотра).
    /// Модель подписана на `store.$currentProject`, поэтому таймлайн и индекс
    /// пересоберутся автоматически.
    func deleteCurrent() {
        guard let project, timeline.indices.contains(index) else { return }
        let item = timeline[index]
        guard project.slides.indices.contains(item.slideIndex) else { return }
        store.removeSlide(id: project.slides[item.slideIndex].id)
    }

    func next() { setIndex(index + 1) }
    func previous() { setIndex(index - 1) }
    func showFirst() { setIndex(0) }
    func showLast() { setIndex(slideCount - 1) }

    func setIndex(_ newIndex: Int) {
        guard slideCount > 0 else { return }
        let clamped = min(max(newIndex, 0), slideCount - 1)
        guard clamped != index else { return }
        index = clamped
        renderCurrent()
    }

    // MARK: - Проект

    private func update(project: SlideshowProject?) {
        guard let project, !project.slides.isEmpty else {
            slideCount = 0
            image = nil
            slideName = ""
            return
        }
        let newSignature = Self.signature(project)
        guard newSignature != signature else { return }
        signature = newSignature
        self.project = project

        let canvas = project.exportSettings.aspectRatio.canvasSize(height: Self.canvasHeight)
        renderer = TimelineFrameRenderer(
            configuration: RenderFrameConfiguration(canvasSize: canvas, renderScale: 1.0)
        )
        timeline = TimelineBuilder.buildTimeline(
            project: project,
            videoDurations: MediaDurationResolver.resolveVideoDurations(project: project)
        )
        slideCount = timeline.count
        if index >= slideCount { index = max(slideCount - 1, 0) }
        renderCurrent()
    }

    private static func signature(_ project: SlideshowProject) -> String {
        // updatedAt меняется при любой правке проекта — этого достаточно,
        // чтобы пересобрать таймлайн и перерисовать кадр.
        "\(project.id.uuidString)|\(project.updatedAt.timeIntervalSince1970)|\(project.exportSettings.aspectRatio.rawValue)|\(project.slides.count)"
    }

    // MARK: - Рендер

    private func renderCurrent() {
        guard let renderer, let project, !timeline.isEmpty else {
            image = nil
            return
        }
        let clamped = min(max(index, 0), timeline.count - 1)
        let item = timeline[clamped]
        let time = item.startTime + max(item.duration, 0) / 2
        slideName = project.slides.indices.contains(item.slideIndex)
            ? project.slides[item.slideIndex].displayName
            : ""

        currentToken += 1
        let token = currentToken
        isRendering = true
        let timeline = self.timeline
        let ciContext = self.ciContext
        let queue = renderQueue
        queue.async { [weak self] in
            var image: NSImage?
            if let ci = try? renderer.makeFrame(at: time, timeline: timeline, project: project),
               let cg = ciContext.createCGImage(ci, from: ci.extent) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                guard let self, token == self.currentToken else { return }
                self.image = image
                self.isRendering = false
            }
        }
    }
}

/// Вид окна увеличенного просмотра слайда.
struct SlideViewerWindowView: View {
    @ObservedObject var model: SlideViewerModel

    var body: some View {
        ZStack {
            Color.black

            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(14)
            } else if model.isRendering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                Text("—")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Нижняя панель: позиция, имя файла, подсказка.
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(model.positionText)
                        .monospacedDigit()
                    Text(model.slideName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L10n.text(.slideViewerHint))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.bottom, 12)
            }

            // Кнопки навигации (мышью).
            HStack {
                navButton(systemImage: "chevron.left", enabled: model.index > 0, action: model.previous)
                Spacer()
                navButton(systemImage: "chevron.right", enabled: model.index + 1 < model.slideCount, action: model.next)
            }
            .padding(.horizontal, 8)
        }
        .frame(minWidth: 480, minHeight: 340)
    }

    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 64)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.25))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
