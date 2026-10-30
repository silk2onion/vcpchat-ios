import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Image decoding and cropping never block the UI actor. Only the small encoded result crosses actors.
public actor AvatarProcessor {
    private var source: CGImage?
    private var animated: Data?
    public var isAnimated: Bool { animated != nil }
    public init() {}
    public func prepare(data: Data) throws {
        guard data.count <= 12_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ClientError.server("请选择不超过 12 MB 的照片") }
        self.source = image
        animated = CGImageSourceGetType(source) as String? == UTType.gif.identifier ? data : nil
    }
    public func prepare(url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12_000_000 else { throw ClientError.server("照片不能超过 12 MB") }
        try prepare(data: Data(contentsOf: url))
    }
    public func crop(zoom: Double, x: Double, y: Double) throws -> String {
        try Task.checkCancellation()
        if let animated { return "data:image/gif;base64," + animated.base64EncodedString() }
        guard let source else { throw ClientError.server("请先选择照片") }
        let side = Double(min(source.width, source.height)) / min(4, max(1, zoom))
        let left = (Double(source.width) - side) * (min(1, max(-1, x)) + 1) / 2
        let top = (Double(source.height) - side) * (min(1, max(-1, y)) + 1) / 2
        let alpha = [CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly].contains(source.alphaInfo)
        guard let cropped = source.cropping(to: CGRect(x: left, y: top, width: side, height: side).integral),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { throw ClientError.server("照片裁剪失败") }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        guard let image = context.makeImage() else { throw ClientError.server("照片裁剪失败") }
        let data = NSMutableData()
        let type = alpha ? UTType.png : .jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw ClientError.server("照片编码失败") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClientError.server("照片编码失败") }
        return "data:" + (type.preferredMIMEType ?? "image/png") + ";base64," + (data as Data).base64EncodedString()
    }
}
