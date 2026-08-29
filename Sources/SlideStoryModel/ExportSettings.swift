import Foundation
import AVFoundation

/// Кодек экспорта.
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case h265

    /// Имя кодера AVFoundation.
    public var avCodecKey: String {
        switch self {
        case .h264: return AVVideoCodecType.h264.rawValue
        case .h265: return AVVideoCodecType.hevc.rawValue
        }
    }
}

/// Частота кадров экспорта.
public enum FrameRate: Int, Codable, CaseIterable, Sendable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30

    /// Число кадров в секунду.
    public var fps: Double { Double(rawValue) }

    /// Длительность одного кадра.
    public var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(rawValue)) }
}

/// Градация качества экспорта (влияет на целевой битрейт).
public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    /// Множитель целевого битрейта относительно базового.
    public var bitrateMultiplier: Double {
        switch self {
        case .low: return 0.5
        case .medium: return 1.0
        case .high: return 1.8
        }
    }

    /// Локализованное имя.
    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Настройки экспорта, сохраняемые в проекте.
///
/// Базовые значения берутся из проекта; в окне экспорта их можно
/// переопределить. Переопределение обратно в файл проекта НЕ сохраняется.
public struct ExportSettings: Codable, Equatable, Sendable {
    /// Базовое соотношение сторон проекта (задаётся в свойствах проекта).
    public var aspectRatio: AspectRatio

    /// Кодек по умолчанию.
    public var codec: VideoCodec

    /// Частота кадров по умолчанию.
    public var frameRate: FrameRate

    /// Качество по умолчанию.
    public var quality: VideoQuality

    public init(
        aspectRatio: AspectRatio = .landscape16x9,
        codec: VideoCodec = .h264,
        frameRate: FrameRate = .fps30,
        quality: VideoQuality = .high
    ) {
        self.aspectRatio = aspectRatio
        self.codec = codec
        self.frameRate = frameRate
        self.quality = quality
    }
}