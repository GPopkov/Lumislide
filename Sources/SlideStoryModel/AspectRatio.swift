import Foundation
import CoreGraphics

/// Соотношения сторон холста.
public enum AspectRatio: String, Codable, CaseIterable, Sendable {
    case landscape16x9
    case portrait9x16
    case square1x1

    /// Ширина к высоте.
    public var ratio: Double {
        switch self {
        case .landscape16x9: return 16.0 / 9.0
        case .portrait9x16: return 9.0 / 16.0
        case .square1x1: return 1.0
        }
    }

    /// Локализованное имя для UI.
    public var displayName: String {
        switch self {
        case .landscape16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .square1x1: return "1:1"
        }
    }

    /// Размер холста для заданной высоты (высоту задаёт рендерер).
    /// - Parameter height: высота холста в пикселях.
    /// - Returns: размер (ширина, высота), кратный 2 (требование кодеков).
    public func canvasSize(height: CGFloat) -> CGSize {
        let width = height * ratio
        let evenWidth = Int(width).evenRoundedDown
        return CGSize(width: CGFloat(evenWidth), height: height)
    }

    /// Стандартные пресеты разрешений для окна экспорта.
    public struct ResolutionPreset: Sendable, Identifiable {
        public let id: String
        public let size: CGSize
    }

    /// Список пресетов: базовый / Full HD / 4K.
    public var presets: [ResolutionPreset] {
        switch self {
        case .landscape16x9:
            return [
                ResolutionPreset(id: "720p", size: CGSize(width: 1280, height: 720)),
                ResolutionPreset(id: "1080p", size: CGSize(width: 1920, height: 1080)),
                ResolutionPreset(id: "4K", size: CGSize(width: 3840, height: 2160)),
            ]
        case .portrait9x16:
            return [
                ResolutionPreset(id: "720p", size: CGSize(width: 720, height: 1280)),
                ResolutionPreset(id: "1080p", size: CGSize(width: 1080, height: 1920)),
                ResolutionPreset(id: "4K", size: CGSize(width: 2160, height: 3840)),
            ]
        case .square1x1:
            return [
                ResolutionPreset(id: "720p", size: CGSize(width: 720, height: 720)),
                ResolutionPreset(id: "1080p", size: CGSize(width: 1080, height: 1080)),
                ResolutionPreset(id: "4K", size: CGSize(width: 2160, height: 2160)),
            ]
        }
    }
}

private extension BinaryInteger {
    /// Ближайшее чётное число не больше значения (вниз).
    var evenRoundedDown: Self {
        self & ~1
    }
}