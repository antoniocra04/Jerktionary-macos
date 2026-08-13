import AppKit
import Foundation
import ImageIO

/// Thread-safe, bounded thumbnail cache for persisted data-URI attachments.
/// Decoding at source resolution inside a SwiftUI body made streaming updates
/// repeatedly allocate multi-megapixel images for a 72-point preview.
final class ChatImageCache: @unchecked Sendable {
    static let shared = ChatImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let maxPixelSize = 192

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func thumbnail(for attachment: ChatAttachment) -> NSImage? {
        let key = "\(attachment.id):\(attachment.dataURL.utf8.count)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let comma = attachment.dataURL.firstIndex(of: ","),
              let data = Data(
                base64Encoded: String(attachment.dataURL[attachment.dataURL.index(after: comma)...])
              ),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(
            image,
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return image
    }
}
