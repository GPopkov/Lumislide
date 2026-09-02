import Foundation

/// Типы переходов между слайдами.
///
/// Часть реализуется встроенными фильтрами Core Image,
/// часть — кастомными Metal-кернелами.
public enum TransitionType: String, Codable, CaseIterable, Sendable {
    /// Растворение (CI)
    case dissolve
    /// Скольжение влево (CI)
    case slideLeft
    /// Скольжение вправо (CI)
    case slideRight
    /// Сдвиг влево (CI)
    case push
    /// Сдвиг вправо (CI)
    case pushRight
    /// Открытие круга (CI)
    case irisOpen
    /// Закрытие круга (CI)
    case irisClose
    /// Затемнение — cross-fade через чёрный (CI)
    case dipToBlack
    /// Дверь (Metal)
    case door
    /// Сетка (Metal)
    case grid
    /// Вспышка — белое проявление (Metal)
    case colorFade

    /// Категория реализации перехода.
    public enum Backend: Sendable {
        case coreImage
        case metal
    }

    /// К какой реализации относится переход.
    public var backend: Backend {
        switch self {
        case .dissolve, .slideLeft, .slideRight, .push, .pushRight,
             .irisOpen, .irisClose, .dipToBlack:
            return .coreImage
        case .door, .grid, .colorFade:
            return .metal
        }
    }

    /// Локализованное имя перехода.
    /// В v1 возвращает английское имя; UI несёт собственную таблицу локализации,
    /// но этот метод удобен для тестов и логирования.
    public var displayName: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .push: return "Push Left"
        case .pushRight: return "Push Right"
        case .irisOpen: return "Iris Open"
        case .irisClose: return "Iris Close"
        case .dipToBlack: return "Dip to Black"
        case .door: return "Door"
        case .grid: return "Grid"
        case .colorFade: return "Flash"
        }
    }
}

public extension TransitionType {
    /// Канонический порядок всех переходов — используется генератором
    /// случайного выбора, чтобы индексы не зависели от порядка `allCases`
    /// при будущих изменениях модели.
    static let transitionOrder: [TransitionType] = [
        .dissolve, .slideLeft, .slideRight, .push, .pushRight,
        .irisOpen, .irisClose, .dipToBlack, .door, .grid, .colorFade,
    ]

    /// Индекс перехода в каноническом порядке (0...11).
    var canonicalIndex: Int {
        Self.transitionOrder.firstIndex(of: self) ?? 0
    }

    /// Переход по индексу в каноническом порядке.
    init?(canonicalIndex: Int) {
        guard Self.transitionOrder.indices.contains(canonicalIndex) else { return nil }
        self = Self.transitionOrder[canonicalIndex]
    }
}

/// Детерминированный генератор переходов на основе seed проекта.
///
/// Один и тот же `(seed, slideIndex)` всегда даёт один и тот же переход,
/// пока `TransitionType.transitionOrder` не меняется.
public enum TransitionPicker {
    /// Возвращает переход для указанного слайда по seed проекта.
    /// - Parameters:
    ///   - seed: 64-битный seed проекта.
    ///   - slideIndex: индекс слайда (0-based), для которого нужен переход.
    /// - Returns: детерминированный тип перехода.
    public static func transition(seed: UInt64, slideIndex: Int) -> TransitionType {
        // SplitMix64: быстрый детерминированный 64-битный PRNG.
        var z = seed &+ (UInt64(truncatingIfNeeded: slideIndex) &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let index = Int(z % UInt64(TransitionType.transitionOrder.count))
        return TransitionType.transitionOrder[index]
    }
}