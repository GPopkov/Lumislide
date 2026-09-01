import AppKit
import SwiftUI
import SlideStoryModel
import SlideStoryRenderer

/// Ячейка `NSCollectionView`: карточка слайда в сетке редактора.
///
/// Показывает: порядковый номер, миниатюру, значок фото/видео,
/// длительность (видео), индикатор наличия титра и рамку при
/// принудительном переходе (см. раздел 3 ТЗ).
final class ThumbnailItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    /// Действие удаления (вызывается кнопкой-крестиком).
    var onDelete: (() -> Void)?
    /// Действие контекстного меню (ПКМ).
    var onRightClick: (() -> Void)?

    // MARK: - UI

    private let thumbnailView = NSImageView()
    private let badgeView = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let titleIndicator = NSImageView()
    private let deleteButton = NSButton()
    /// Индикатор принудительного перехода: значок + название перехода.
    private let transitionIndicator = NSStackView()
    private let transitionIcon = NSImageView()
    private let transitionLabel = NSTextField(labelWithString: "")

    private var slide: MediaReference?
    /// Доступен ли файл слайда (управляет красной рамкой).
    private var isFileAvailable = true

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 150))

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        root.addSubview(thumbnailView)

        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = .secondaryLabelColor
        root.addSubview(numberLabel)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badgeView)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = .secondaryLabelColor
        root.addSubview(durationLabel)

        titleIndicator.translatesAutoresizingMaskIntoConstraints = false
        titleIndicator.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        titleIndicator.toolTip = L10n.text(.hasTitle)
        root.addSubview(titleIndicator)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        root.addSubview(deleteButton)

        // Индикатор принудительного перехода: чип «значок + название».
        transitionIndicator.translatesAutoresizingMaskIntoConstraints = false
        transitionIndicator.orientation = .horizontal
        transitionIndicator.spacing = 3
        transitionIndicator.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        transitionIndicator.wantsLayer = true
        transitionIndicator.layer?.cornerRadius = 8
        transitionIndicator.layer?.masksToBounds = true
        transitionIndicator.layer?.backgroundColor = NSColor.systemOrange.cgColor

        transitionIcon.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        transitionIcon.contentTintColor = .white
        transitionIcon.translatesAutoresizingMaskIntoConstraints = false

        transitionLabel.translatesAutoresizingMaskIntoConstraints = false
        transitionLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        transitionLabel.textColor = .white
        transitionLabel.lineBreakMode = .byTruncatingTail

        transitionIndicator.addArrangedSubview(transitionIcon)
        transitionIndicator.addArrangedSubview(transitionLabel)
        transitionIndicator.isHidden = true
        root.addSubview(transitionIndicator)

        // Слежение за hover для показа крестика.
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        root.addTrackingArea(trackingArea)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            thumbnailView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            thumbnailView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            // Высота миниатюры масштабируется вместе с размером ячейки
            // (ползунок размера миниатюр): 110/150 — базовое отношение.
            thumbnailView.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 110.0 / 150.0),

            numberLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            numberLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),

            badgeView.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 6),
            badgeView.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: 6),
            badgeView.widthAnchor.constraint(equalToConstant: 20),
            badgeView.heightAnchor.constraint(equalToConstant: 20),

            durationLabel.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -4),
            durationLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -6),

            titleIndicator.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: 2),
            titleIndicator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            titleIndicator.widthAnchor.constraint(equalToConstant: 14),
            titleIndicator.heightAnchor.constraint(equalToConstant: 14),

            deleteButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            deleteButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            deleteButton.widthAnchor.constraint(equalToConstant: 18),
            deleteButton.heightAnchor.constraint(equalToConstant: 18),

            transitionIndicator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            transitionIndicator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            transitionIndicator.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            transitionIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: numberLabel.trailingAnchor, constant: 8),

            transitionIcon.widthAnchor.constraint(equalToConstant: 12),
            transitionIcon.heightAnchor.constraint(equalToConstant: 12),

            transitionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])

        self.view = root
    }



    // MARK: - Configure

    func configure(
        slide: MediaReference,
        index: Int,
        thumbnail: NSImage?,
        transitionName: String?,
        isForced: Bool
    ) {
        self.slide = slide

        thumbnailView.image = thumbnail
        numberLabel.stringValue = "\(index + 1)"

        switch slide.kind {
        case .photo:
            badgeView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            durationLabel.stringValue = ""
        case .video:
            badgeView.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
            if let duration = slide.cachedVideoDuration {
                durationLabel.stringValue = Self.formatDuration(duration)
            } else {
                durationLabel.stringValue = L10n.text(.video)
            }
        }

        titleIndicator.isHidden = slide.titleOverlay == nil

        // Индикатор принудительного перехода: значок + название перехода
        // (вместо цветной рамки, которая не читалась как «переход»).
        if isForced, let transitionName {
            transitionIndicator.isHidden = false
            transitionLabel.stringValue = transitionName
            transitionIndicator.toolTip = "\(L10n.text(.transitionLabel)): \(transitionName)"
        } else {
            transitionIndicator.isHidden = true
        }

        // Доступность файла: красная рамка + тултип.
        isFileAvailable = MediaResolver.isAvailable(slide)
        thumbnailView.toolTip = isFileAvailable
            ? (transitionName.map { "\(L10n.text(.transitionLabel)): \($0)" } ?? nil)
            : L10n.text(.fileNotAvailable)
        updateAppearance()
    }

    /// Выделение слайда мышью (устанавливается NSCollectionView).
    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    /// Рисует состояние ячейки: выделение акцентной рамкой/подсветкой,
    /// недоступный файл — красной рамкой.
    private func updateAppearance() {
        guard let layer = thumbnailView.layer else { return }
        if !isFileAvailable {
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemRed.cgColor
            layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        } else if isSelected {
            layer.borderWidth = 3
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = NSColor.clear.cgColor
            layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        deleteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        deleteButton.isHidden = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    // MARK: - Actions

    @objc private func deleteTapped() {
        onDelete?()
    }
}
