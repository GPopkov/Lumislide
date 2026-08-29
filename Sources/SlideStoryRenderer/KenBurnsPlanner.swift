import Foundation
import CoreGraphics
import SlideStoryModel

/// Траектория эффекта Кена Бёрнса для одного слайда.
///
/// Описывает интерполяцию «исходный прямоугольник → конечный прямоугольник»
/// в нормализованных координатах изображения (0...1, origin — верхний левый).
public struct KenBurnsTrajectory: Sendable {
    /// Начальный прямоугольник (нормализованные координаты).
    public var startRect: CGRect
    /// Конечный прямоугольник.
    public var endRect: CGRect
    /// Продолжительность движения (длительность слайда).
    public var duration: Double

    /// Прямоугольник в момент времени t (0...1).
    public func rect(atTime t: Double) -> CGRect {
        let clamped = min(max(t, 0), 1)
        let originX = startRect.origin.x + (endRect.origin.x - startRect.origin.x) * clamped
        let originY = startRect.origin.y + (endRect.origin.y - startRect.origin.y) * clamped
        let width = startRect.width + (endRect.width - startRect.width) * clamped
        let height = startRect.height + (endRect.height - startRect.height) * clamped
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

/// Планировщик траекторий Кена Бёрнса.
///
/// Точка интереса детерминирована: зависит от `seed` проекта и индекса
/// слайда (тот же принцип, что и для переходов). Если на фото найдены
/// лица — точка интереса смещается к объединяющему прямоугольнику лиц;
/// иначе — правило третей.
public enum KenBurnsPlanner {
    /// Минимальный масштаб кадра (начало движения).
    public static let minScale: Double = 1.0
    /// Максимальный масштаб кадра (конец движения) — «дышащий» кадр.
    public static let maxScale: Double = 1.12

    /// Строит траекторию для фото-слайда.
    /// - Parameters:
    ///   - seed: seed проекта (детерминизм).
    ///   - slideIndex: индекс слайда.
    ///   - duration: длительность слайда в секундах.
    ///   - faceRegions: найденные лица (пусто — fallback на правило третей).
    /// - Returns: траектория движения.
    public static func trajectory(
        seed: UInt64,
        slideIndex: Int,
        duration: Double,
        faceRegions: [FaceRegion]
    ) -> KenBurnsTrajectory {
        let interestPoint: CGPoint
        if let union = FaceRegion.union(of: faceRegions) {
            // Центр объединяющего прямоугольника лиц.
            interestPoint = CGPoint(
                x: union.x + union.width / 2,
                y: union.y + union.height / 2
            )
        } else {
            interestPoint = ruleOfThirds(seed: seed, slideIndex: slideIndex)
        }

        let direction = directionVector(seed: seed, slideIndex: slideIndex)
        let scale = scaleRange(seed: seed, slideIndex: slideIndex)

        // Прямоугольники строим так, чтобы точка интереса оставалась
        // видимой в обоих состояниях движения.
        let startRect = rect(center: interestPoint, scale: scale.start)
        let endRect = rect(center: interestPoint, scale: scale.end, direction: direction)

        // Нормализация: прямоугольники не должны выходить за границы кадра.
        return KenBurnsTrajectory(
            startRect: clamped(startRect),
            endRect: clamped(endRect),
            duration: max(duration, 0.1)
        )
    }

    /// Следование правилу третей: точка интереса выбирается одна из 4 точек
    /// пересечения линий третей детерминированно по seed.
    private static func ruleOfThirds(seed: UInt64, slideIndex: Int) -> CGPoint {
        var z = seed &+ (UInt64(truncatingIfNeeded: slideIndex) &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let quadrant = Int(z % 4)
        switch quadrant {
        case 0: return CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0)
        case 1: return CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0)
        case 2: return CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0)
        default: return CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0)
        }
    }

    /// Детерминированный единичный вектор направления движения.
    private static func directionVector(seed: UInt64, slideIndex: Int) -> CGVector {
        var z = seed &+ (UInt64(truncatingIfNeeded: slideIndex &* 31) &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let angle = Double(z % 360) * .pi / 180.0
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    /// Диапазон масштаба: либо zoom-in, либо zoom-out (детерминированно).
    private static func scaleRange(seed: UInt64, slideIndex: Int) -> (start: Double, end: Double) {
        var z = seed &+ (UInt64(truncatingIfNeeded: slideIndex &* 17) &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let zoomsIn = (z & 1) == 0
        if zoomsIn {
            return (minScale, maxScale)
        } else {
            return (maxScale, minScale)
        }
    }

    /// Строит прямоугольник заданного масштаба вокруг точки интереса.
    private static func rect(center: CGPoint, scale: Double, direction: CGVector = .zero) -> CGRect {
        // Базовое смещение: небольшой сдвиг точки интереса в направлении,
        // чтобы движение не было «статичным» зумом.
        let offsetX = direction.dx * 0.08
        let offsetY = direction.dy * 0.08

        let zoomedWidth = 1.0 / scale
        let zoomedHeight = 1.0 / scale
        let width = zoomedWidth
        let height = zoomedHeight
        let centerX = center.x + offsetX * (1.0 / scale)
        let centerY = center.y + offsetY * (1.0 / scale)
        return CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    /// Обрезает прямоугольник так, чтобы он оставался внутри кадра
    /// и сохранял пропорции.
    private static func clamped(_ rect: CGRect) -> CGRect {
        var r = rect
        // Аспект прямоугольника всегда квадратный (1/scale), вписывание
        // в кадр (0...1) гарантирует видимость.
        let minX: CGFloat = 0
        let maxX: CGFloat = 1
        let minY: CGFloat = 0
        let maxY: CGFloat = 1

        if r.minX < minX { r.origin.x = minX }
        if r.maxX > maxX { r.origin.x = maxX - r.width }
        if r.minY < minY { r.origin.y = minY }
        if r.maxY > maxY { r.origin.y = maxY - r.height }
        if r.width > 1 { r = CGRect(x: 0, y: 0, width: 1, height: 1) }
        if r.height > 1 { r = CGRect(x: 0, y: 0, width: 1, height: 1) }
        return r
    }
}