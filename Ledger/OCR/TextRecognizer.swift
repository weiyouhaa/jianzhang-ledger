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
    /// 运行日志只记录尺寸、耗时、行数，不记录识别出的文字。
    static func recognizeOCRLines(in data: Data, maxPixel: Int = TextRecognizer.maxPixel) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 解码 + 识别都放在 autoreleasepool 里：快捷指令在后台运行时内存上限较低，用完立即释放位图
                let result: Result<[OCRLine], Error> = autoreleasepool {
                    let t0 = Date()
                    // 不缓存原图解码结果；只按需生成缩略图（不做整图解码）
                    guard let source = CGImageSourceCreateWithData(data as CFData,
                                                                   [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetCount(source) > 0 else {
                        RunLog.shared.log(.error, "ocr-decode", "无法读取图片")
                        return .failure(RecognizerError.invalidImage)
                    }
                    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
                    let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
                    let type = (CGImageSourceGetType(source) as String?) ?? "?"
                    RunLog.shared.log(.info, "ocr-input", "图片 \(type) \(w)×\(h)，\(data.count / 1024) KB")
                    guard let cgImage = thumbnail(source, maxPixel: maxPixel) else {
                        RunLog.shared.log(.error, "ocr-decode", "缩略图解码失败")
                        return .failure(RecognizerError.invalidImage)
                    }
                    RunLog.shared.log(.info, "ocr-decoded",
                                      "解码为 \(cgImage.width)×\(cgImage.height)，用时 \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    let t1 = Date()
                    RunLog.shared.log(.info, "vision-start", "Vision 文字识别开始（accurate，zh-Hans / en-US）")
                    let visionResult: Result<[OCRLine], Error> = autoreleasepool {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["zh-Hans", "en-US"]
                        request.usesLanguageCorrection = true
                        request.minimumTextHeight = 0.008
                        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                        do {
                            try handler.perform([request])
                            return .success(groupIntoLines(request.results ?? []))
                        } catch {
                            return .failure(error)
                        }
                    }
                    let ms = Int(Date().timeIntervalSince(t1) * 1000)
                    switch visionResult {
                    case .success(let lines):
                        RunLog.shared.log(.info, "vision-end", "Vision 完成，用时 \(ms) ms，\(lines.count) 行")
                    case .failure(let error):
                        let ns = error as NSError
                        RunLog.shared.log(.error, "vision-end", "Vision 失败，用时 \(ms) ms：\(ns.domain) \(ns.code)")
                    }
                    return visionResult
                }
                continuation.resume(with: result)
            }
        }
    }

    /// 统一用缩略图解码：长边最多 2000 px（截图 2796 px → 2000 px，文字仍清晰），方向烘焙进位图。
    /// 不走 CGImageSourceCreateImageAtIndex 整图解码，后台运行时内存峰值更低。
    static let maxPixel = 2000

    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
}
