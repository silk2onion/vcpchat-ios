import Foundation
import CoreGraphics
import ImageIO

/// Decode each embedded avatar once, not again for every streamed token.
public actor AvatarImageCache {
    public static let shared = AvatarImageCache()
    private var images: [String: CGImage] = [:]
    private var recent: [String] = []
    public init() {}
    public func image(_ source: String) -> CGImage? {
        guard source.hasPrefix("data:image/"), source.utf8.count <= 16_000_000 else { return nil }
        if let image = images[source] { touch(source); return image }
        guard let comma = source.firstIndex(of: ","), let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let input = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        images[source] = image; touch(source)
        if recent.count > 32 { images.removeValue(forKey: recent.removeLast()) }
        return image
    }
    private func touch(_ source: String) { recent.removeAll { $0 == source }; recent.insert(source, at: 0) }
}
