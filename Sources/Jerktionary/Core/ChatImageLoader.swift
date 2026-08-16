import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns files and pasted images into the base64 data: URIs the backend takes.
enum ChatImageLoader {
    /// Mirrors the backend's per-message cap, so the limit is reported before a
    /// pointless round trip.
    static let maxPerMessage = 8
    /// The backend rejects data URIs over 8 MB of base64. Anything larger is
    /// downscaled rather than refused: a screenshot from a Retina display is
    /// routinely bigger than this and carries no extra detail for a model.
    static let maxBase64Bytes = 7_000_000
    /// Longest edge after downscaling. Above this, vision models tile the image
    /// anyway, so the extra pixels only cost upload time and tokens.
    static let maxPixelDimension: CGFloat = 1568

    static let allowedTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Reads a file, keeping its original bytes when they are already small and a
    /// format every provider accepts; re-encodes otherwise.
    static func attachment(fromFile url: URL) throws -> ChatAttachment {
        let data = try Data(contentsOf: url)
        let mediaType = mediaType(for: url)

        if allowedTypes.contains(mediaType), data.count * 4 / 3 <= maxBase64Bytes {
            return ChatAttachment(
                id: ChatMessage.freshID(),
                dataURL: "data:\(mediaType);base64,\(data.base64EncodedString())",
                name: url.lastPathComponent
            )
        }

        guard let image = NSImage(data: data),
              let attachment = attachment(from: image, name: url.lastPathComponent)
        else {
            throw BackendError(
                message: "Could not read the image \(url.lastPathComponent)",
                status: 0
            )
        }
        return attachment
    }

    /// Re-encodes an in-memory image as PNG, downscaling until it fits.
    static func attachment(from image: NSImage, name: String) -> ChatAttachment? {
        var candidate = image
        for _ in 0..<6 {
            guard let data = png(from: candidate) else { return nil }
            if data.count * 4 / 3 <= maxBase64Bytes {
                return ChatAttachment(
                    id: ChatMessage.freshID(),
                    dataURL: "data:image/png;base64,\(data.base64EncodedString())",
                    name: name
                )
            }
            guard let smaller = scaled(candidate, by: 0.7) else { return nil }
            candidate = smaller
        }
        return nil
    }

    private static func png(from image: NSImage) -> Data? {
        let bounded = fitted(image) ?? image
        guard let tiff = bounded.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Scales down to `maxPixelDimension` on the longest edge; returns nil when
    /// the image is already small enough.
    private static func fitted(_ image: NSImage) -> NSImage? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxPixelDimension, longest > 0 else { return nil }
        return scaled(image, by: maxPixelDimension / longest)
    }

    private static func scaled(_ image: NSImage, by factor: CGFloat) -> NSImage? {
        let target = NSSize(
            width: max(1, (image.size.width * factor).rounded()),
            height: max(1, (image.size.height * factor).rounded())
        )
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()
        return output
    }

    private static func mediaType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return "application/octet-stream"
        }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        return type.preferredMIMEType ?? "application/octet-stream"
    }
}
