import Foundation
import Vision
import ImageIO
import CoreGraphics

/// 设备端 OCR（Vision），不联网
enum TextRecognizer {
    enum RecognizerError: Error {
        case invalidImage
    }

    /// 识别图片中的文字，按「行」返回（同一水平线上的文本块会合并成一行，从上到下排序）
    static func recognizeLines(in data: Data) async throws -> [String] {
        try await recognizeOCRLines(in: data).map(\.text)
    }

    /// 带位置信息的行（midY：0 = 顶部，1 = 底部；height：该行最高文本块的高度），用于多笔拆分与大字金额识别
    static func recognizeOCRLines(in data: Data) async throws -> [OCRLine] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw RecognizerError.invalidImage
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 解码 + 识别都放在 autoreleasepool 里：快捷指令在后台运行时内存上限较低，用完立即释放位图
                let result: Result<[OCRLine], Error> = autoreleasepool {
                    guard let (cgImage, orientation) = decode(source) else {
                        return .failure(RecognizerError.invalidImage)
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    request.minimumTextHeight = 0.008
                    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                    do {
                        try handler.perform([request])
                        return .success(groupIntoLines(request.results ?? []))
                    } catch {
                        return .failure(error)
                    }
                }
                continuation.resume(with: result)
            }
        }
    }

    /// 长边超过 maxPixel 时按比例缩小（截图 2796 px → 2400 px，文字仍清晰），并把方向烘焙进位图
    static let maxPixel = 2400

    private static func decode(_ source: CGImageSource) -> (CGImage, CGImagePropertyOrientation)? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if max(w, h) > maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (thumb, .up)
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, imageOrientation(source))
    }

    private struct Block {
        let text: String
        let midY: CGFloat
        let minX: CGFloat
        let height: CGFloat
    }

    /// Vision 坐标原点在左下角，y 越大越靠上
    private static func groupIntoLines(_ observations: [VNRecognizedTextObservation]) -> [OCRLine] {
        let blocks: [Block] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox
            return Block(text: candidate.string, midY: box.midY, minX: box.minX, height: box.height)
        }
        .sorted { $0.midY > $1.midY }

        var rows: [[Block]] = []
        for block in blocks {
            if let last = rows.last, let ref = last.first,
               abs(ref.midY - block.midY) < max(ref.height, block.height) * 0.5 {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.map { row in
            let text = row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
            let mid = row.map(\.midY).reduce(0, +) / CGFloat(row.count)
            let height = row.map(\.height).max() ?? 0
            return OCRLine(text, midY: Double(1 - mid), height: Double(height))
        }
    }

    private static func imageOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }
}
