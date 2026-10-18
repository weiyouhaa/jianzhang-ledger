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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RecognizerError.invalidImage
        }
        let orientation = imageOrientation(source)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                request.minimumTextHeight = 0.008

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    continuation.resume(returning: groupIntoLines(observations))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct Block {
        let text: String
        let midY: CGFloat
        let minX: CGFloat
        let height: CGFloat
    }

    /// Vision 坐标原点在左下角，y 越大越靠上
    private static func groupIntoLines(_ observations: [VNRecognizedTextObservation]) -> [String] {
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
            row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
        }
    }

    private static func imageOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }
}

/// OCR + 解析的组合入口，App 内「从截图识别」和快捷指令共用
enum ReceiptRecognizer {
    static func recognize(imageData: Data) async throws -> ParsedReceipt {
        let lines = try await TextRecognizer.recognizeLines(in: imageData)
        return ReceiptParser.parse(lines: lines)
    }
}
