import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EmbeddedRaster: Sendable {
    public var data: Data
    public var width: Double
    public var height: Double
}

public actor EmbeddedImages {
    public static let shared = EmbeddedImages()
    private var items: [String: EmbeddedRaster] = [:]
    private var recent: [String] = []
    public init() {}
    public func raster(_ source: String) -> EmbeddedRaster? {
        if let value = items[source] { touch(source); return value }
        guard source.hasPrefix("data:image/"), source.utf8.count <= 16_000_000, let comma = source.firstIndex(of: ","), let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let image = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = [5, 6, 7, 8].contains(orientation)
        let value = EmbeddedRaster(data: data, width: swapped ? height : width, height: swapped ? width : height)
        items[source] = value; touch(source)
        if recent.count > 8 { items.removeValue(forKey: recent.removeLast()) }
        return value
    }
    private func touch(_ key: String) { recent.removeAll { $0 == key }; recent.insert(key, at: 0) }
    public func importWallpaper(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw ClientError.server("图片不能超过 8 MB") }
        return try prepareWallpaper(Data(contentsOf: url))
    }
    public func prepareWallpaper(_ data: Data) throws -> String {
        guard data.count <= 8_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw ClientError.server("请选择不超过 8 MB 的图片") }
        if CGImageSourceGetType(source) as String? == UTType.gif.identifier { return "data:image/gif;base64," + data.base64EncodedString() }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ClientError.server("无法读取图片") }
        let alpha = [CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly].contains(image.alphaInfo)
        let type = alpha ? UTType.png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw ClientError.server("图片编码失败") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClientError.server("图片编码失败") }
        return "data:" + (type.preferredMIMEType ?? "image/png") + ";base64," + (output as Data).base64EncodedString()
    }
}
