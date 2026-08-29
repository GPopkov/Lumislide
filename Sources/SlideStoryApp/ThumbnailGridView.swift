import SwiftUI
import AppKit
import AVFoundation
import SlideStoryModel

/// SwiftUI-обёртка над `NSCollectionView` для сетки миниатюр.
///
/// Стандартный `LazyVGrid` в SwiftUI не поддерживает reorder внутри сетки,
/// поэтому используется `NSCollectionView` через `NSViewRepresentable`
/// (см. раздел 3 ТЗ). Порядок карточек = порядок слайдов в проекте.
struct ThumbnailGridView: NSViewRepresentable {
    let project: SlideshowProject

    @EnvironmentObject private var store: ProjectsStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 150)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.register(
            ThumbnailItem.self,
            forItemWithIdentifier: ThumbnailItem.identifier
        )
        collectionView.registerForDraggedTypes([.string])

        scrollView.documentView = collectionView

        context.coordinator.collectionView = collectionView
        context.coordinator.updateSlides(project.slides)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.updateSlides(project.slides)
        context.coordinator.reloadIfNeeded()
    }
}


    // MARK: - Coordinator (dataSource + delegate)

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSCollectionViewDelegateFlowLayout {
        var store: ProjectsStore
        weak var collectionView: NSCollectionView?

        private var slides: [MediaReference] = []
        private var thumbnails: [UUID: NSImage] = [:]
        /// Слайды, для которых миниатюра уже запрошена (избегаем дублей).
        private var loadingThumbnails: Set<UUID> = []
        private var isReloading = false

        init(store: ProjectsStore) {
            self.store = store
        }

        func updateSlides(_ slides: [MediaReference]) {
            self.slides = slides
        }

        func reloadIfNeeded() {
            guard let collectionView, !isReloading else { return }
            collectionView.reloadData()
        }

        // MARK: DataSource

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            slides.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            guard let thumbItem = item as? ThumbnailItem else { return item }

            let index = indexPath.item
            let slide = slides[index]
            thumbItem.configure(
                slide: slide,
                index: index,
                thumbnail: thumbnail(for: slide),
                transitionName: transitionName(for: slide, index: index),
                isForced: slide.transitionOverride != nil
            )
            thumbItem.onDelete = { [weak self] in
                self?.store.removeSlide(id: slide.id)
            }
            thumbItem.onRightClick = { [weak self] in
                self?.makeMenu(for: slide, index: index)
            }
            return thumbItem
        }

        // MARK: Drag & Drop reorder

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            true
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let pb = NSPasteboardItem()
            pb.setString(String(indexPath.item), forType: .string)
            return pb
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop proposedDropInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            .move
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let sourceString = draggingInfo.draggingPasteboard.string(forType: .string),
                  let sourceIndex = Int(sourceString),
                  slides.indices.contains(sourceIndex) else { return false }

            var destination = indexPath.item
            if sourceIndex < destination { destination -= 1 }
            guard destination != sourceIndex else { return false }

            store.moveSlide(from: sourceIndex, to: min(destination, slides.count - 1))
            return true
        }

        // MARK: Helpers

        private func transitionName(for slide: MediaReference, index: Int) -> String? {
            guard let project = store.currentProject,
                  index < project.slides.count - 1 else { return nil }
            return project.transitionType(at: index).map(L10n.transitionName)
        }

        private func thumbnail(for slide: MediaReference) -> NSImage? {
            if let cached = thumbnails[slide.id] { return cached }
            // Миниатюры генерируются в фоне (чтение файла / первый кадр видео
            // могут быть медленными и не должны блокировать главный поток).
            loadThumbnail(for: slide)
            return placeholder(for: slide)
        }

        private func placeholder(for slide: MediaReference) -> NSImage? {
            switch slide.kind {
            case .photo:
                return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            case .video:
                return NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            }
        }

        /// Асинхронно генерирует миниатюру (дисковый кэш → чтение/первый кадр)
        /// и обновляет ячейку по готовности.
        private func loadThumbnail(for slide: MediaReference) {
            guard !loadingThumbnails.contains(slide.id) else { return }
            loadingThumbnails.insert(slide.id)

            let id = slide.id
            let bookmark = slide.bookmarkData
            let kind = slide.kind
            let cache = ThumbnailCache.shared

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let resolved = try? BookmarkResolver.resolve(bookmark) else {
                    DispatchQueue.main.async { [weak self] in
                        self?.loadingThumbnails.remove(id)
                    }
                    return
                }
                let cacheKey = cache.key(for: resolved.url)

                let result: NSImage?
                if let cached = cache.image(forKey: cacheKey) {
                    result = cached
                } else {
                    switch kind {
                    case .photo:
                        result = NSImage(contentsOf: resolved.url)
                    case .video:
                        result = Self.firstVideoFrame(url: resolved.url)
                    }
                    if let result {
                        cache.store(result, forKey: cacheKey)
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    self?.loadingThumbnails.remove(id)
                    guard let result else { return }
                    self?.thumbnails[id] = result
                    self?.reloadItem(id)
                }
            }
        }

        /// Перерисовывает одну ячейку сетки (после готовности миниатюры).
        private func reloadItem(_ id: UUID) {
            guard let collectionView,
                  let index = slides.firstIndex(where: { $0.id == id }) else { return }
            collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
        }

        /// Извлекает первый кадр видео (для миниатюры).
        /// Вызывается из фонового потока — не должен трогать main-actor state.
        nonisolated private static func firstVideoFrame(url: URL) -> NSImage? {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        private func makeMenu(for slide: MediaReference, index: Int) {
            let menu = NSMenu()

            let autoItem = NSMenuItem(title: L10n.text(.automaticRandom), action: #selector(setAutoTransition), keyEquivalent: "")
            autoItem.target = self
            autoItem.representedObject = slide.id
            autoItem.state = slide.transitionOverride == nil ? .on : .off
            menu.addItem(autoItem)

            let transitionMenu = NSMenuItem(title: L10n.text(.forceTransition), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for type in TransitionType.transitionOrder {
                let item = NSMenuItem(title: L10n.transitionName(type), action: #selector(setTransition), keyEquivalent: "")
                item.target = self
                item.representedObject = slide.id
                item.tag = type.canonicalIndex
                if slide.transitionOverride == type { item.state = .on }
                submenu.addItem(item)
            }
            transitionMenu.submenu = submenu
            menu.addItem(transitionMenu)

            menu.addItem(.separator())

            let titleItem = NSMenuItem(title: L10n.text(.addTitle), action: #selector(addTitle), keyEquivalent: "t")
            titleItem.target = self
            titleItem.representedObject = slide.id
            menu.addItem(titleItem)

            let kbItem = NSMenuItem(title: L10n.text(.disableKenBurns), action: #selector(toggleKenBurns), keyEquivalent: "")
            kbItem.target = self
            kbItem.representedObject = slide.id
            kbItem.state = slide.isKenBurnsDisabled ? .on : .off
            kbItem.isEnabled = slide.kind == .photo
            menu.addItem(kbItem)

            menu.addItem(.separator())

            let relink = NSMenuItem(title: L10n.text(.relinkFile), action: #selector(relink), keyEquivalent: "")
            relink.target = self
            relink.representedObject = slide.id
            menu.addItem(relink)

            let delete = NSMenuItem(title: L10n.text(.delete), action: #selector(deleteSlide), keyEquivalent: "\u{8}")
            delete.target = self
            delete.representedObject = slide.id
            menu.addItem(delete)

            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: collectionView ?? NSView())
            }
        }

        // MARK: Actions

        @objc private func setAutoTransition(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            store.updateSlide(id: id) { $0.transitionOverride = nil }
        }

        @objc private func setTransition(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID,
                  let type = TransitionType(canonicalIndex: sender.tag) else { return }
            store.updateSlide(id: id) { $0.transitionOverride = type }
        }

        @objc private func addTitle(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID,
                  let window = collectionView?.window else { return }
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheet.title = L10n.text(.title)
            sheet.isReleasedWhenClosed = false
            // ВАЖНО: weak-capture окна и sheet — иначе retain cycle
            // sheet → rootView → onClose → sheet, краш при закрытии.
            sheet.contentViewController = NSHostingController(
                rootView: TitleEditorView(slideID: id, store: store, onClose: { [weak window, weak sheet] in
                    if let sheet, let window {
                        window.endSheet(sheet)
                    }
                })
            )
            window.beginSheet(sheet)
        }

        @objc private func toggleKenBurns(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            store.updateSlide(id: id) { slide in
                slide.isKenBurnsDisabled.toggle()
            }
        }

        @objc private func relink(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            store.relinkSlide(id: id)
        }

        @objc private func deleteSlide(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            store.removeSlide(id: id)
        }
    }

