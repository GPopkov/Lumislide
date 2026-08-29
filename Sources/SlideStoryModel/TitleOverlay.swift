import Foundation
import CoreGraphics
import simd

/// Позиция титра на кадре.
public enum TitlePosition: String, Codable, CaseIterable, Sendable {
    case top
    case center
    case bottom

    /// Доля вертикальной позиции (0.0 — верх, 1.0 — низ) центра текста.
    /// Для v1: top ≈ 12%, center ≈ 50%, bottom ≈ 88% высоты кадра.
    public var normalizedY: CGFloat {
        switch self {
        case .top: return 0.12
        case .center: return 0.5
        case .bottom: return 0.88
        }
    }
}

/// Простой текстовый титр поверх слайда.
///
/// В v1 — один титр на медиа-элемент: текст, размер шрифта, цвет, позиция.
/// Несколько слоёв текста, анимации и шаблоны — вне рамок v1.
public struct TitleOverlay: Codable, Equatable, Sendable {
    /// Текст титра.
    public var text: String
    /// Размер шрифта в пунктах. Хранится в «эталонных» пунктах дизайна
    /// (относительно базовой высоты кадра 1080), при рендере масштабируется
    /// пропорционально фактическому разрешению холста.
    public var fontSize: Double
    /// Цвет текста в формате RGBA 0...1.
    public var colorRGBA: SIMD4<Double>
    /// Позиция на кадре.
    public var position: TitlePosition

    public init(
        text: String,
        fontSize: Double = 48,
        colorRGBA: SIMD4<Double> = SIMD4(1, 1, 1, 1),
        position: TitlePosition = .center
    ) {
        self.text = text
        self.fontSize = fontSize
        self.colorRGBA = colorRGBA
        self.position = position
    }

    // MARK: - Codable
    // SIMD4 не реализует Codable — кодируем цвет массивом из 4 элементов.

    private enum CodingKeys: String, CodingKey {
        case text, fontSize, colorRGBA, position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        let components = try container.decodeIfPresent([Double].self, forKey: .colorRGBA) ?? [1, 1, 1, 1]
        colorRGBA = SIMD4<Double>(array: components)
        position = try container.decodeIfPresent(TitlePosition.self, forKey: .position) ?? .center
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(colorRGBA.arrayValue, forKey: .colorRGBA)
        try container.encode(position, forKey: .position)
    }
}

extension TitleOverlay {
    /// Удобный доступ к цвету как к CGColor (для Core Graphics).
    public var cgColor: CGColor {
        CGColor(
            red: colorRGBA.x,
            green: colorRGBA.y,
            blue: colorRGBA.z,
            alpha: colorRGBA.w
        )
    }
}

/// Варианты представления цвета для совместимости с Codable.
extension SIMD4 where Scalar == Double {
    /// Кодирование как массива из 4 элементов.
    public init(array: [Double]) {
        self.init(array[safe: 0] ?? 0,
                  array[safe: 1] ?? 0,
                  array[safe: 2] ?? 0,
                  array[safe: 3] ?? 1)
    }

    /// Представление в виде массива из 4 элементов.
    public var arrayValue: [Double] { [x, y, z, w] }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
