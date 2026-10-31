import Foundation
import ImageIO
import Photos

/// 截图本身的时间（2.0 (19)）：截图里找不到交易时间时，用它作为账单时间。
/// 顺序：照片库里的创建时间（仅在已有照片权限时读取，不会弹权限）→ 图片内嵌的拍摄时间（EXIF / XMP）
/// → 图片文件的创建时间（排除刚复制出来的临时文件）。都拿不到返回 nil（由调用方再看状态栏时钟 / 现在）。
enum ScreenshotTime {
    static func capture(data: Data, assetIdentifier: String? = nil, fileURL: URL? = nil,
                        now: Date = Date()) -> CaptureTime? {
        if let d = photoAssetDate(assetIdentifier), CaptureTime.isPlausibleCapture(d, now: now) {
            return CaptureTime(date: d, source: .screenshot)
        }
        if let d = embeddedDate(in: data), CaptureTime.isPlausibleCapture(d, now: now) {
            return CaptureTime(date: d, source: .screenshot)
        }
        if let d = fileDate(fileURL, now: now), CaptureTime.isPlausibleCapture(d, now: now) {
            return CaptureTime(date: d, source: .file)
        }
        return nil
    }

    /// 照片库资源的创建时间。只在用户已经授权（完全 / 有限）时读取；未授权 / 未决定时直接返回 nil，不请求权限。
    static func photoAssetDate(_ identifier: String?) -> Date? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.creationDate
    }

    /// 图片内嵌的拍摄时间：EXIF DateTimeOriginal / DateTimeDigitized（iOS 截图也会写）→ TIFF DateTime
    /// → XMP photoshop:DateCreated / xmp:CreateDate → PNG CreationTime。只读元数据，不解码图片。
    static func embeddedDate(in data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        let tz = TimeZone.current
        let pairs: [(Any?, Any?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifOffsetTimeOriginal]),
            (exif[kCGImagePropertyExifDateTimeDigitized], exif[kCGImagePropertyExifOffsetTimeDigitized]),
            (tiff[kCGImagePropertyTIFFDateTime], exif[kCGImagePropertyExifOffsetTime]),
        ]
        for (value, offset) in pairs {
            if let s = value as? String, let d = CaptureTime.parseMetadataDate(s, offset: offset as? String, timeZone: tz) { return d }
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            for path in ["photoshop:DateCreated", "xmp:CreateDate", "exif:DateTimeOriginal"] {
                if let cf = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString),
                   let d = CaptureTime.parseMetadataDate(cf as String, timeZone: tz) { return d }
            }
        }
        if let s = png[kCGImagePropertyPNGCreationTime] as? String, let d = CaptureTime.parseMetadataDate(s, timeZone: tz) { return d }
        return nil
    }

    /// 文件创建时间（快捷指令 / 共享传入的文件）。2 分钟内刚创建的多半是系统复制出来的临时文件，没有意义。
    static func fileDate(_ url: URL?, now: Date) -> Date? {
        guard let url, url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else { return nil }
        guard let d = [values.creationDate, values.contentModificationDate].compactMap({ $0 }).min(),
              d < now.addingTimeInterval(-120) else { return nil }
        return d
    }
}
