import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreImage

private enum AttachmentBudget {
    static let sourceImage = 20_000_000
    static let sentImage = 1_500_000
    static let text = 200_000
}

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mime: String
    public var kind: String
    public var dataUrl: String?
    public var text: String?
    public var hash: String?
    public var desktopOnly: Bool?
    public init(id: String = UUID().uuidString, name: String, mime: String, kind: String, dataUrl: String? = nil, text: String? = nil, hash: String? = nil, desktopOnly: Bool? = nil) {
        self.id = id; self.name = name; self.mime = mime; self.kind = kind; self.dataUrl = dataUrl; self.text = text; self.hash = hash; self.desktopOnly = desktopOnly
    }
    public var bytes: Data? {
        if let dataUrl, let comma = dataUrl.firstIndex(of: ",") { return Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...])) }
        return text.map { Data($0.utf8) }
    }
}
public actor AttachmentImporter {
    public init() {}
    public func read(_ url: URL) throws -> ChatAttachment {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let image = type?.conforms(to: .image) == true
        guard size <= (image ? AttachmentBudget.sourceImage : AttachmentBudget.text) else { throw ClientError.server(image ? "图片原文件不能超过 20 MB" : "文本附件不能超过 200 KB") }
        return try prepare(Data(contentsOf: url), name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream")
    }
    public func prepare(_ data: Data, name: String, mime: String) throws -> ChatAttachment {
        let mime = mime.lowercased(), ext = (name as NSString).pathExtension.lowercased()
        guard mime != "image/svg+xml", ext != "svg" else { throw ClientError.server("不接受 SVG 附件") }
        if mime.hasPrefix("image/") || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            guard data.count <= AttachmentBudget.sourceImage else { throw ClientError.server("\(name) 原文件超过 20 MB") }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0,
                  let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else { throw ClientError.server("无法读取图片") }
            // Keep already-sendable images byte-for-byte, including existing GIF animation.
            if data.count <= AttachmentBudget.sentImage, [.jpeg, .png, .gif, .webP].contains(type) {
                return imageAttachment(data, name: name, mime: type.preferredMIMEType ?? mime)
            }
            guard CGImageSourceGetCount(source) == 1 else { throw ClientError.server("动画图片不能超过 1.5 MB，请选择较小的动画或静态图片") }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw ClientError.server("无法处理这张图片") }
            return try compressedAttachment(CIImage(cgImage: image), name: name)
        }
        guard mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime) || ["txt", "md", "json", "csv", "log", "xml", "yaml", "yml"].contains(ext) else { throw ClientError.server("\(name) 不是图片或文本") }
        guard data.count <= AttachmentBudget.text else { throw ClientError.server("\(name) 超过 200 KB") }
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.server("文本附件需要 UTF-8 编码") }
        return ChatAttachment(name: name, mime: mime, kind: "text", text: text, hash: SyncWire.sha(data))
    }
    /// Camera pixels cross into this actor without UIKit objects or capture metadata.
    /// Normalize orientation and size here, leaving the UI free while encoding.
    public func prepareCameraPhoto(_ image: CGImage, orientation: UInt32, name: String) throws -> ChatAttachment {
        guard (1...8).contains(orientation) else { throw ClientError.server("无法识别照片方向") }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        return try compressedAttachment(oriented, name: name)
    }
    private func imageAttachment(_ data: Data, name: String, mime: String) -> ChatAttachment {
        ChatAttachment(name: name, mime: mime, kind: "image", dataUrl: "data:\(mime);base64," + data.base64EncodedString(), hash: SyncWire.sha(data))
    }
    private func compressedAttachment(_ image: CIImage, name: String) throws -> ChatAttachment {
        let name = (name as NSString).deletingPathExtension + ".jpg"
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
        let opaque = image.composited(over: background)
        let context = CIContext(options: [.cacheIntermediates: false])
        for maxSide in [2560.0, 1920.0, 1280.0] {
            let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
            let resized = opaque.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let bounds = CGRect(origin: resized.extent.origin, size: CGSize(width: resized.extent.width.rounded(.down), height: resized.extent.height.rounded(.down)))
            guard let raster = context.createCGImage(resized, from: bounds) else { throw ClientError.server("无法处理图片") }
            for quality in [0.85, 0.65, 0.45] {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ClientError.server("照片编码失败") }
                CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ClientError.server("照片编码失败") }
                if data.length <= AttachmentBudget.sentImage { return imageAttachment(data as Data, name: name, mime: "image/jpeg") }
            }
        }
        throw ClientError.server("图片压缩后仍超过 1.5 MB，请选择较小的图片")
    }
    public static func assertCount(_ current: Int, adding: Int) throws { guard current + adding <= 4 else { throw ClientError.server("最多 4 个附件") } }
}
public struct APIContentPart: Codable, Sendable, Equatable {
    public struct ImageURL: Codable, Sendable, Equatable { public var url: String }
    public var type: String
    public var text: String?
    public var image_url: ImageURL?
    public static func text(_ value: String) -> Self { Self(type: "text", text: value) }
    public static func image(_ value: String) -> Self { Self(type: "image_url", image_url: ImageURL(url: value)) }
}
public enum AttachmentContext {
    public static func parts(text: String, attachments: [ChatAttachment]) -> [APIContentPart] {
        var blocks = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        var images: [APIContentPart] = []
        for attachment in attachments {
            if attachment.kind == "text", let body = attachment.text, body.utf8.count <= AttachmentBudget.text {
                // Synced extracted text is usable even before the original file
                // has downloaded. desktopOnly applies to the missing binary.
                blocks.append("附件 \(attachment.name):\n\(body)")
            } else if attachment.kind == "image", attachment.desktopOnly != true,
                      let url = attachment.dataUrl, let bytes = attachment.bytes, bytes.count <= AttachmentBudget.sentImage {
                images.append(.image(url))
            } else {
                let reason = attachment.desktopOnly == true ? "原件尚未下载" : "内容不可用或超过单个附件大小限制"
                blocks.append("【附件 \(attachment.name)：\(reason)，本次未附带内容】")
            }
        }
        let merged = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (merged.isEmpty ? [] : [.text(merged)]) + images
    }
}
