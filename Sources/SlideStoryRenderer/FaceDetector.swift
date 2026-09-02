import Foundation
import Vision
import CoreImage
import SlideStoryModel

/// Ошибки детекции лиц.
public enum FaceDetectionError: Error, LocalizedError, Sendable {
    case invalidImage
    case detectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Could not read the image for face detection."
        case .detectionFailed(let message):
            return "Face detection failed: \(message)"
        }
    }
}

/// Обёртка над Vision для поиска лиц на фото.
///
/// Используется `VNDetectFaceRectanglesRequest` — определяется только
/// местоположение лиц (bounding box), без идентификации личности и
/// без landmarks. Это самый дешёвый режим Vision, работает on-device
/// через Neural Engine.
public enum FaceDetector {

    /// Находит лица на изображении.
    ///
    /// Для скорости изображение предварительно уменьшается до ~1600 px
    /// по большей стороне: Vision ищет лица в нормализованных координатах,
    /// поэтому точность позиций не страдает, а стоимость (декод + рендер +
    /// детекция) падает в разы.
    /// - Parameter ciImage: изображение (фото-слайд).
    /// - Returns: массив нормализованных прямоугольников лиц
    ///   (координаты Vision: origin — верхний левый, 0...1).
    public static func detectFaces(in ciImage: CIImage) async throws -> [FaceRegion] {
        let cgImage: CGImage
        guard let cg = try? convertToCGImage(downscaled(ciImage)) else {
            throw FaceDetectionError.invalidImage
        }
        cgImage = cg
        return try performDetection(on: cgImage)
    }

    /// Находит лица в ФАЙЛЕ изображения, декодируя его сразу в уменьшенном
    /// разрешении (без полного декода большого фото — быстрее и легче).
    /// - Parameter url: URL файла изображения (jpg/heic/png).
    public static func detectFaces(inImageAt url: URL) async throws -> [FaceRegion] {
        try detectFacesSync(inImageAt: url)
    }

    /// Синхронная детекция по файлу (для фоновых serial-очередей).
    public static func detectFacesSync(inImageAt url: URL) throws -> [FaceRegion] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FaceDetectionError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FaceDetectionError.invalidImage
        }
        return try performDetection(on: cgImage)
    }

    /// Общая часть детекции по уже готовому CGImage (Vision синхронен).
    private static func performDetection(on cgImage: CGImage) throws -> [FaceRegion] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { observation in
            // Vision возвращает boundingBox в координатах с origin внизу-слева
            // (нормализованные). Конвертируем в верхний-левый origin,
            // чтобы совпадать с `FaceRegion`.
            let box = observation.boundingBox
            return FaceRegion(
                x: Double(box.origin.x),
                y: Double(1.0 - box.origin.y - box.height),
                width: Double(box.width),
                height: Double(box.height)
            )
        }
    }

    /// Уменьшает изображение перед детекцией (если оно больше лимита).
    private static func downscaled(_ image: CIImage) -> CIImage {
        let maxDimension: CGFloat = 1600
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Синхронный вариант (используется в тестах и ранних стадиях).
    public static func detectFacesSync(in ciImage: CIImage) throws -> [FaceRegion] {
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task { try await detectFaces(in: ciImage) }
        var result: Result<[FaceRegion], Error>?
        Task {
            do {
                let faces = try await task.value
                result = .success(faces)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    // MARK: - Internals

    private static func convertToCGImage(_ ciImage: CIImage) throws -> CGImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw FaceDetectionError.invalidImage
        }
        return cgImage
    }
}