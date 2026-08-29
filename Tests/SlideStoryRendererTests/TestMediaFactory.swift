import Foundation
import CoreGraphics
import AVFoundation

/// Фабрика тестовых медиа-файлов (синтетическое видео, WAV, mux с более
/// длинным аудио) для тестов рендерера.
enum TestMediaFactory {

    /// Создаёт короткое видео (H.264) фиксированного цвета.
    /// - Parameters:
    ///   - url: путь выходного файла.
    ///   - duration: длительность в секундах.
    ///   - fps: частота кадров.
    ///   - w, h: размер кадра.
    static func makeBaseVideo(url: URL, duration: Double = 5, fps: Int32 = 10, w: Int = 160, h: Int = 120) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer!, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer!),
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])

        let total = Int(duration * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(pixelBuffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "TestMediaFactory", code: 1) }
    }

    /// Создаёт WAV-файл (PCM) с синусоидой.
    static func writeWAV(url: URL, duration: Double, sampleRate: Int = 44100) throws {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let dataSize = Int(duration * Double(byteRate))
        var data = Data()

        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendLE<T: FixedWidthInteger>(_ v: T) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }

        appendString("RIFF")
        appendLE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))                 // PCM
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(channels * bitsPerSample / 8))
        appendLE(UInt16(bitsPerSample))
        appendString("data")
        appendLE(UInt32(dataSize))
        for i in 0..<(dataSize / 2) {
            let v = Int16(sin(2 * Double.pi * 220 * Double(i) / Double(sampleRate)) * 12000)
            appendLE(v)
        }
        try data.write(to: url)
    }

    /// Муксирует видео и аудио в MP4 (passthrough). Аудио может быть длиннее
    /// видео — тогда контейнерная длительность будет больше видеодорожки
    /// (типичный случай «запись экрана», при котором кадров в «хвосте» нет).
    static func mux(videoURL: URL, audioURL: URL, out: URL) throws {
        let composition = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        let aAsset = AVURLAsset(url: audioURL)
        guard let vTrack = vAsset.tracks(withMediaType: .video).first,
              let aTrack = aAsset.tracks(withMediaType: .audio).first,
              let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "TestMediaFactory", code: 2) }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: vTrack, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: aAsset.duration), of: aTrack, at: .zero)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        session.outputURL = out
        session.outputFileType = .mp4
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        sem.wait()
        guard session.status == .completed else { throw session.error ?? NSError(domain: "TestMediaFactory", code: 3) }
    }
}
